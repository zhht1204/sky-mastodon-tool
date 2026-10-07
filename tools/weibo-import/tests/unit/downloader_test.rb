# frozen_string_literal: true

require 'weibo_import/downloader'

class DownloaderTest < Minitest::Test
  D = WeiboImport::Downloader

  PUBLIC_RESOLVER = ->(_host) { ['93.184.216.34'] }  # 示例保留公网 IP

  # ---- 私网/保留地址拒绝 ----

  def test_ip_allowed_rejects_private_and_reserved_ranges
    %w[
      10.0.0.1 10.255.255.255
      172.16.0.1 172.31.255.255
      192.168.1.1 192.168.0.100
      127.0.0.1 127.8.8.8
      169.254.169.254 169.254.0.1
      100.64.0.1 100.100.100.200
      0.0.0.1 224.0.0.1 239.1.1.1 240.0.0.1 255.255.255.255
      192.0.2.1 198.51.100.1 203.0.113.1 198.18.0.1 192.0.0.8
    ].each { |ip| refute D.ip_allowed?(ip), "应拒绝 #{ip}" }
  end

  def test_ip_allowed_rejects_ipv6_special_ranges
    %w[:: ::1 fe80::1 fc00::1 fd12:3456::1 ff02::1 2001:db8::1].each { |ip| refute D.ip_allowed?(ip), "应拒绝 #{ip}" }
  end

  def test_ip_allowed_unwraps_v4_mapped_ipv6
    refute D.ip_allowed?('::ffff:192.168.0.1')
    refute D.ip_allowed?('[::ffff:10.0.0.1]')
    refute D.ip_allowed?('::ffff:169.254.169.254')
    assert D.ip_allowed?('::ffff:93.184.216.34')
  end

  def test_ip_allowed_accepts_public
    %w[93.184.216.34 1.1.1.1 8.8.8.8 2606:4700:4700::1111 2001:4860:4860::8888].each { |ip| assert D.ip_allowed?(ip), "应允许 #{ip}" }
  end

  # ---- 域名校验（可注入 resolver）----

  def test_host_allowed_requires_all_resolved_ips_public
    assert D.host_allowed?('cdn.example.synthetic', resolver: ->(_h) { ['93.184.216.34', '1.1.1.1'] })
    refute D.host_allowed?('evil.example.synthetic', resolver: ->(_h) { ['93.184.216.34', '192.168.0.1'] })
    refute D.host_allowed?('nodns.example.synthetic', resolver: ->(_h) { [] })
  end

  def test_host_allowed_literal_ip_and_metadata_hostnames
    refute D.host_allowed?('192.168.1.5', resolver: PUBLIC_RESOLVER) # 字面私网 IP 直接拒绝
    refute D.host_allowed?('127.0.0.1', resolver: PUBLIC_RESOLVER)
    assert D.host_allowed?('93.184.216.34', resolver: PUBLIC_RESOLVER)
    refute D.host_allowed?('metadata.google.internal', resolver: PUBLIC_RESOLVER)
    refute D.host_allowed?('169.254.169.254', resolver: PUBLIC_RESOLVER)
    refute D.host_allowed?('', resolver: PUBLIC_RESOLVER)
    refute D.host_allowed?(nil, resolver: PUBLIC_RESOLVER)
  end

  # ---- URL 校验与重定向 ----

  def test_validate_url_scheme_and_host
    uri = D.validate_url('https://cdn.example.synthetic/a.jpg', resolver: PUBLIC_RESOLVER)
    assert_equal 'cdn.example.synthetic', uri.host

    assert_raises(D::Rejected) { D.validate_url('ftp://cdn.example.synthetic/a.jpg', resolver: PUBLIC_RESOLVER) }
    assert_raises(D::Rejected) { D.validate_url('file:///etc/passwd', resolver: PUBLIC_RESOLVER) }
    assert_raises(D::Rejected) { D.validate_url('https://192.168.0.1/a.jpg', resolver: PUBLIC_RESOLVER) }
    assert_raises(D::Rejected) { D.validate_url('https://internal.example.synthetic/a.jpg', resolver: ->(_h) { ['10.1.2.3'] }) }
    assert_raises(D::Rejected) { D.validate_url('::not a url::', resolver: PUBLIC_RESOLVER) }
  end

  def test_redirect_target_resolves_relative_and_rejects_non_http
    base = URI.parse('https://cdn.example.synthetic/a')
    assert_equal URI.parse('https://cdn.example.synthetic/b'), D.redirect_target(base, '/b')
    assert_equal URI.parse('https://other.example/c'), D.redirect_target(base, 'https://other.example/c')
    assert_raises(D::Rejected) { D.redirect_target(base, 'file:///etc/passwd') }
    assert_raises(D::Rejected) { D.redirect_target(base, 'javascript:alert(1)') }
    assert_raises(D::Rejected) { D.redirect_target(base, '') }
  end

  # ---- 路径穿越防御 ----

  def test_safe_target_path_accepts_plain_names
    base = FIXTURES_DIR
    target = D.safe_target_path(base, 'w01.jpg')
    assert_equal File.expand_path(File.join(base, 'w01.jpg')), target
    assert target.start_with?(File.expand_path(base))
  end

  def test_safe_target_path_rejects_traversal
    base = FIXTURES_DIR
    ['../escape.jpg', '..\\escape.jpg', 'a/b.jpg', 'a\\b.jpg', '..', 'sub/../w.jpg'].each do |name|
      e = assert_raises(D::Rejected, "应拒绝 #{name}") { D.safe_target_path(base, name) }
      assert(e.message =~ /穿越|分隔|逃逸/, "拒绝原因应指向路径安全: #{e.message}")
    end
  end

  def test_safe_target_path_rejects_drive_letter_and_control_chars
    base = FIXTURES_DIR
    assert_raises(D::Rejected) { D.safe_target_path(base, 'C:\\Windows\\evil.jpg') }
    assert_raises(D::Rejected) { D.safe_target_path(base, "evil\x00.jpg") }
    assert_raises(D::Rejected) { D.safe_target_path(base, "evil\n.jpg") }
    assert_raises(D::Rejected) { D.safe_target_path(base, '') }
    assert_raises(D::Rejected) { D.safe_target_path(base, '   ') }
    assert_raises(D::Rejected) { D.safe_target_path(base, nil) }
    refute_match(/\.\./, D.safe_target_path(base, 'w01.jpg')) # 正常名不受影响
  end

  # ---- 文件名推导与魔数嗅探 ----

  def test_filename_from_uri
    assert_equal 'a.jpg', D.filename_from_uri(URI.parse('https://x.example.synthetic/p/a.jpg?sign=1'))
    assert_includes D.filename_from_uri(URI.parse('https://x.example.synthetic/')), 'download'
    assert_includes D.filename_from_uri(URI.parse('https://x.example.synthetic/noext')), 'x.example.synthetic'
  end

  def test_sniff_mime_magic_bytes
    assert_equal 'image/jpeg', D.sniff_mime("\xFF\xD8\xFF\xE0")
    assert_equal 'image/png', D.sniff_mime("\x89PNG\r\n\x1A\n")
    assert_equal 'image/gif', D.sniff_mime('GIF89a')
    assert_equal 'video/webm', D.sniff_mime("\x1A\x45\xDF\xA3\x00")
    assert_equal 'video/mp4', D.sniff_mime("\x00\x00\x00\x20ftypisom")
    assert_equal 'image/webp', D.sniff_mime("RIFF\x00\x00\x00\x00WEBPVP8 ")
    assert_equal 'image/bmp', D.sniff_mime('BM\x36')
    assert_nil D.sniff_mime('')
    assert_nil D.sniff_mime('random-bytes-no-magic')
  end

  def test_extension_matches
    assert D.extension_matches?('a.jpg', 'image/jpeg')
    assert D.extension_matches?('a.jpg', nil) # 嗅探不出不算不符
    assert D.extension_matches?('a.bin', nil)
    refute D.extension_matches?('a.jpg', 'image/png')
    assert D.extension_matches?('a.mp4', 'video/mp4')
  end

  def test_coerce_ipaddr_invalid_returns_nil
    assert_nil D.coerce_ipaddr('not-an-ip')
    assert_nil D.coerce_ipaddr('')
    assert_kind_of IPAddr, D.coerce_ipaddr('1.2.3.4')
    refute D.literal_ip?('example.com')
    assert D.literal_ip?('1.2.3.4')
  end
end
