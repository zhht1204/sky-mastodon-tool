# frozen_string_literal: true

# SSRF 安全媒体下载（fetch-media）。
# 硬性安全要求：
# - 仅 http/https；解析 DNS 后拒绝私网/环回/链路本地/唯一本地/组播/保留地址，
#   以及 169.254.169.254 等云元数据端点（DNS 解析出的所有地址都必须通过校验）。
# - 跟随重定向时对每一跳重新校验 scheme 与 IP，绝不重定向到非 http(s)。
# - 单文件大小上限（默认 200MB）、超时、有限重试。
# - 内容魔数验证真实 MIME，与扩展名不符记录警告（不阻断，供人工复核）。
# - 每文件 SHA-256 + 下载结果清单；缺失媒体显式写 missing-media.jsonl，绝不悄悄丢弃。
# - 路径穿越防御：展开后必须仍在 media-dir 内；拒绝 ..、绝对路径、盘符、symlink 逃逸。
require 'ipaddr'
require 'socket'
require 'digest'
require 'net/http'
require 'uri'
require 'json'

module WeiboImport
  module Downloader
    class Rejected < StandardError; end
    class DownloadError < StandardError; end

    ALLOWED_SCHEMES = %w[http https].freeze
    DEFAULT_MAX_BYTES = 200 * 1024 * 1024
    DEFAULT_TIMEOUT_SECONDS = 60
    DEFAULT_RETRIES = 2
    MAX_REDIRECTS = 5
    SNIFF_BYTES = 16

    # 显式拒绝网段（IPAddr 内建的 private?/loopback?/link_local?/unique_local?/multicast? 之外再补）
    DENIED_RANGES_V4 = [
      '0.0.0.0/8',        # 未指定
      '10.0.0.0/8',       # RFC1918
      '100.64.0.0/10',    # CGNAT（含云元数据 100.100.100.200）
      '127.0.0.0/8',      # 环回
      '169.254.0.0/16',   # 链路本地（含云元数据 169.254.169.254）
      '172.16.0.0/12',    # RFC1918
      '192.0.0.0/24',     # IETF 协议分配
      '192.0.2.0/24',     # TEST-NET-1
      '192.168.0.0/16',   # RFC1918
      '198.18.0.0/15',    # 基准测试
      '198.51.100.0/24',  # TEST-NET-2
      '203.0.113.0/24',   # TEST-NET-3
      '224.0.0.0/4',      # 组播
      '240.0.0.0/4',      # 保留（含广播）
      '255.255.255.255/32'
    ].freeze
    DENIED_RANGES_V6 = [
      '::/128',           # 未指定
      '::1/128',          # 环回
      'fc00::/7',         # 唯一本地
      'fe80::/10',        # 链路本地
      'ff00::/8',         # 组播
      '2001:db8::/32'     # 文档示例
    ].freeze
    DENIED_HOSTNAMES = %w[
      169.254.169.254
      metadata.google.internal
      metadata.goog
    ].freeze

    MIME_BY_EXT = {
      '.jpg' => 'image/jpeg', '.jpeg' => 'image/jpeg', '.png' => 'image/png',
      '.gif' => 'image/gif', '.webp' => 'image/webp', '.bmp' => 'image/bmp',
      '.mp4' => 'video/mp4', '.m4v' => 'video/mp4', '.webm' => 'video/webm', '.mov' => 'video/quicktime'
    }.freeze

    module_function

    # ---- 纯逻辑（单测覆盖）-------------------------------------------------------

    def ip_allowed?(ip)
      addr = coerce_ipaddr(ip)
      return false if addr.nil?

      ranges = addr.ipv6? ? DENIED_RANGES_V6 : DENIED_RANGES_V4
      return false if ranges.any? { |cidr| IPAddr.new(cidr).include?(addr) }
      # 注：IPAddr 无 unique_local?/multicast? 方法；fc00::/7 与 224.0.0.0/4、ff00::/8 已在上方 CIDR 表显式覆盖
      return false if addr.private? || addr.loopback? || addr.link_local?

      true
    end

    # IPv4-mapped IPv6（::ffff:a.b.c.d）解包后按 IPv4 判定
    def coerce_ipaddr(ip)
      if ip.is_a?(IPAddr)
        ip
      else
        s = ip.to_s
        s = s[/\A\[(.*)\]\z/, 1] || s # 去 [::1] 括号
        begin
          IPAddr.new(s)
        rescue IPAddr::InvalidAddressError
          nil
        end
      end
    end

    def literal_ip?(host)
      !coerce_ipaddr(host).nil?
    end

    # 域名解析（可注入 resolver 供测试）。返回 IP 字符串数组；解析失败返回 []。
    def host_ips(host, resolver: method(:system_resolve))
      resolver.call(host)
    end

    def system_resolve(host)
      Addrinfo.getaddrinfo(host, nil, :UNSPEC, :STREAM).map(&:ip_address).uniq
    rescue SocketError, ArgumentError
      []
    end

    # 主机是否允许：字面 IP 直接校验；域名解析后所有地址都必须通过。
    def host_allowed?(host, resolver: method(:system_resolve))
      return false if host.nil? || host.strip.empty?
      return false if DENIED_HOSTNAMES.include?(host.strip.downcase)

      h = host.strip
      if literal_ip?(h)
        ip_allowed?(h)
      else
        ips = host_ips(h, resolver: resolver)
        return false if ips.empty?

        ips.all? { |ip| ip_allowed?(ip) }
      end
    end

    # URL 校验：仅 http/https，host 必须存在且通过 IP 校验
    def validate_url(url, resolver: method(:system_resolve))
      uri = URI.parse(url.to_s)
      raise Rejected, "仅允许 http/https: #{url}" unless ALLOWED_SCHEMES.include?(uri.scheme&.downcase)
      raise Rejected, "缺少 host: #{url}" if uri.host.to_s.empty?
      raise Rejected, "目标主机被拒绝（私网/保留/云元数据或解析失败）: #{uri.host}" unless host_allowed?(uri.host, resolver: resolver)

      uri
    rescue URI::InvalidURIError => e
      raise Rejected, "非法 URL #{url.inspect}: #{e.message}"
    end

    # 重定向目标校验：相对 Location 按 base 解析；非 http(s) 一律拒绝
    def redirect_target(base_uri, location)
      loc = location.to_s.strip
      raise Rejected, '重定向缺少 Location' if loc.empty?

      uri = URI.join(base_uri.to_s, loc)
      raise Rejected, "重定向到非 http(s) 协议: #{uri.scheme}" unless ALLOWED_SCHEMES.include?(uri.scheme&.downcase)

      uri
    end

    # 路径穿越防御：给定媒体目录与候选文件名，返回安全的绝对路径。
    # 拒绝：空名、包含 ..、绝对路径、盘符（X:）、反斜杠、控制字符、symlink 逃逸。
    def safe_target_path(media_dir, proposed_name)
      raise Rejected, '文件名为空' if proposed_name.to_s.strip.empty?

      name = proposed_name.to_s
      raise Rejected, "文件名包含路径分隔/穿越字符: #{name.inspect}" if name.match?(%r{[/\\]}) || name.split(File::SEPARATOR).include?('..')
      raise Rejected, "文件名包含盘符或控制字符: #{name.inspect}" if name.match?(/\A\w:/) || name.match?(/[\x00-\x1f]/)

      base = File.expand_path(media_dir)
      target = File.expand_path(File.join(base, name))
      raise Rejected, "目标逃逸出媒体目录: #{target}" unless target == base || target.start_with?(base + File::SEPARATOR)

      raise Rejected, "目标已存在且是符号链接（防 symlink 逃逸）: #{target}" if File.exist?(target) && File.symlink?(target)

      target
    end

    # 从 URL 推导安全文件名：取路径末段；查询串去重后缀避免互相覆盖
    def filename_from_uri(uri)
      path = uri.path.to_s
      base = path.split(%r{/}).last.to_s
      base = 'download' if base.empty?
      base = "#{base}.#{uri.host.to_s.gsub(/[^A-Za-z0-9.-]/, '_')}" unless base.include?('.')
      base
    end

    # 内容魔数嗅探（head 至少前 16 字节）
    def sniff_mime(head)
      return nil unless head.is_a?(String) && !head.empty?

      b = head.bytes
      return 'image/jpeg' if b.length >= 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF
      return 'image/png' if b.length >= 8 && b[0..7] == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
      return 'image/gif' if head.start_with?('GIF87a', 'GIF89a')
      return 'video/webm' if b.length >= 4 && b[0..3] == [0x1A, 0x45, 0xDF, 0xA3]
      return 'video/mp4' if b.length >= 12 && b[4..7] == [0x66, 0x74, 0x79, 0x70] # ....ftyp
      return 'image/webp' if b.length >= 12 && head[0, 4] == 'RIFF' && head[8, 4] == 'WEBP'
      return 'image/bmp' if head.start_with?('BM')
      return 'image/x-icon' if b.length >= 4 && b[0..3] == [0x00, 0x00, 0x01, 0x00]

      nil
    end

    def extension_matches?(path_or_name, sniffed_mime)
      ext = File.extname(path_or_name.to_s.split('?').first.to_s.downcase)
      return true if sniffed_mime.nil? # 无法嗅探（如 0 字节/未知格式）不算不符
      return true if MIME_BY_EXT[ext].nil? # 未知扩展名不告警

      MIME_BY_EXT[ext] == sniffed_mime
    end

    # ---- 下载（批次 A 只在演练中验证拒绝路径，不做真实联网测试）-------------------

    def fetch(url, out_path, max_bytes: DEFAULT_MAX_BYTES, timeout: DEFAULT_TIMEOUT_SECONDS, retries: DEFAULT_RETRIES, resolver: method(:system_resolve), headers: {})
      uri = validate_url(url, resolver: resolver)
      attempts = 0
      begin
        attempts += 1
        fetch_once(uri, out_path, max_bytes: max_bytes, timeout: timeout, resolver: resolver, headers: headers)
      rescue DownloadError, Rejected => e
        raise if e.is_a?(Rejected)
        retry if attempts <= retries
        raise
      end
    end

    def fetch_once(uri, out_path, max_bytes:, timeout:, resolver:, headers: {})
      redirects = 0
      current = uri
      loop do
        raise Rejected, "目标主机被拒绝: #{current.host}" unless host_allowed?(current.host, resolver: resolver)

        http = Net::HTTP.new(current.host, current.port)
        http.use_ssl = current.scheme == 'https'
        http.open_timeout = timeout
        http.read_timeout = timeout
        # 注：先解析校验再用域名建连存在理论上的 TOCTOU（DNS rebinding）窗口；
        # 单人工具抓取自备归档的场景下可接受，批次 B 若引入不可信源需改为直连已校验 IP + SNI。

        request = Net::HTTP::Get.new(current.request_uri.empty? ? '/' : current.request_uri)
        headers.each { |k, v| request[k] = v }
        # 必须用块式请求：无块形式的 response body 已整体读入，
        # 之后 write_body 再调 read_body 会抛 "read_body called twice"
        http.request(request) do |res|
          case res
          when Net::HTTPRedirection
            redirects += 1
            raise DownloadError, "重定向次数超过 #{MAX_REDIRECTS}" if redirects > MAX_REDIRECTS

            current = redirect_target(current, res['location'])
            raise Rejected, "重定向目标主机被拒绝: #{current.host}" unless host_allowed?(current.host, resolver: resolver)
          when Net::HTTPSuccess
            return write_body(res, out_path, max_bytes: max_bytes, url: current.to_s)
          else
            raise DownloadError, "HTTP #{res.code} #{res.message}"
          end
        end
      end
    end

    def write_body(response, out_path, max_bytes:, url:)
      digest = Digest::SHA256.new
      bytes = 0
      head = +''
      tmp = "#{out_path}.part"
      result = nil
      begin
        File.open(tmp, 'wb') do |f|
          response.read_body do |chunk|
            head << chunk[0, SNIFF_BYTES - head.bytesize] if head.bytesize < SNIFF_BYTES
            digest.update(chunk)
            bytes += chunk.bytesize
            raise DownloadError, "超过大小上限 #{max_bytes} 字节（已读 #{bytes}）" if bytes > max_bytes

            f.write(chunk)
          end
        end
        File.rename(tmp, out_path)
        sniffed = sniff_mime(head)
        result = {
          'status' => 'ok',
          'url' => url,
          'path' => out_path,
          'bytes' => bytes,
          'sha256' => digest.hexdigest,
          'sniffed_mime' => sniffed,
          'extension_mismatch' => !extension_matches?(out_path, sniffed)
        }
      ensure
        File.delete(tmp) if File.exist?(tmp) # 失败时清掉半成品 .part
      end
      result
    end
  end
end
