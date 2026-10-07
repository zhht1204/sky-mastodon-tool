# frozen_string_literal: true

require 'weibo_import/adapter'
require 'weibo_import/normalize'

class NormalizeTest < Minitest::Test
  MAP = WeiboImport::Adapter::Map.load(File.join(FIXTURES_DIR, 'field_map.synthetic.yml')).freeze

  # 注：helper 用位置参数（Ruby 3.4.11 下「字符串键无括号哈希 + 方法关键字参数」会误报
  # ArgumentError: wrong number of arguments，见 tests 内注释），调用点全部走位置传参。
  def normalize(rec, map = MAP, now = nil, line = nil)
    WeiboImport::Normalize.normalize_record(rec, map, index: 0, original_line: line, now: now)
  end

  # ---- resolve_tz / 时区 ----

  def test_resolve_tz_aliases_and_offsets
    assert_equal '+08:00', WeiboImport::Normalize.resolve_tz('Asia/Shanghai')
    assert_equal '+08:00', WeiboImport::Normalize.resolve_tz('asia/shanghai')
    assert_equal '+08:00', WeiboImport::Normalize.resolve_tz('+08:00')
    assert_equal '+08:00', WeiboImport::Normalize.resolve_tz('+0800')
    assert_equal '-05:30', WeiboImport::Normalize.resolve_tz('-05:30')
    assert_equal '+08:00', WeiboImport::Normalize.resolve_tz('') # 缺省微博主时区
    assert_raises(ArgumentError) { WeiboImport::Normalize.resolve_tz('Mars/Olympus') }
  end

  def test_parse_time_keeps_original_offset
    t = WeiboImport::Normalize.parse_time('2020-05-06T07:08:09+08:00')
    assert_equal '+08:00', t.iso8601[19, 6]
    assert_equal '2020-05-06T07:08:09+08:00', t.iso8601
  end

  def test_parse_time_without_offset_uses_default
    t = WeiboImport::Normalize.parse_time('2019-08-08 08:09:10', default_offset: '+08:00')
    assert_equal '2019-08-08T08:09:10+08:00', t.iso8601
    t2 = WeiboImport::Normalize.parse_time('2019-08-08 08:09:10', default_offset: '+00:00')
    assert_equal '2019-08-08T08:09:10+00:00', t2.iso8601
  end

  def test_parse_time_epoch_seconds_and_ms
    assert_equal '2020-05-05T23:08:10Z', WeiboImport::Normalize.parse_time(1_588_720_090).utc.iso8601
    assert_equal '2020-05-05T23:08:10Z', WeiboImport::Normalize.parse_time(1_588_720_090_000).utc.iso8601
    assert_equal '2020-05-05T23:08:10Z', WeiboImport::Normalize.parse_time('1588720090000').utc.iso8601
  end

  def test_parse_time_rejects_illegal_and_out_of_window
    assert_raises(WeiboImport::Normalize::RecordError) { WeiboImport::Normalize.parse_time('not-a-valid-time') }
    assert_raises(WeiboImport::Normalize::RecordError) { WeiboImport::Normalize.parse_time('') }
    assert_raises(WeiboImport::Normalize::RecordError) { WeiboImport::Normalize.parse_time(nil) }
    assert_raises(WeiboImport::Normalize::RecordError) { WeiboImport::Normalize.parse_time(1.23) } # epoch 量级异常
    assert_raises(WeiboImport::Normalize::RecordError) { WeiboImport::Normalize.parse_time('2008-12-31T23:59:59+08:00') } # 早于 2009

    now = Time.utc(2026, 1, 1)
    assert_raises(WeiboImport::Normalize::RecordError) { WeiboImport::Normalize.parse_time('2099-01-01T00:00:00+08:00', now: now) }
    # 容差内（24h）的未来时间允许
    assert_equal '2026-01-01T12:00:00Z', WeiboImport::Normalize.parse_time('2026-01-01T12:00:00Z', now: now).utc.iso8601
    # 2009-01-01T00:00:00Z 恰好在窗口下沿，允许
    assert_equal '2009-01-01T00:00:00Z', WeiboImport::Normalize.parse_time('2009-01-01T00:00:00Z', now: now).utc.iso8601
  end

  def test_time_zone_of
    n = WeiboImport::Normalize
    assert_equal '原偏移', n.time_zone_of('2020-01-01T00:00:00+08:00', '+08:00')
    assert_equal '原偏移', n.time_zone_of('2020-01-01T00:00:00Z', '+08:00')
    assert_equal 'default+08:00', n.time_zone_of('2020-01-01 00:00:00', '+08:00')
    assert_equal 'epoch→UTC', n.time_zone_of(1_587_128_890_000, '+08:00')
  end

  # ---- normalize_record 契约 ----

  CONTRACT_KEYS = %w[source source_id source_url created_at text visibility media reply_to_source_id repost raw_record_sha256 extra].freeze

  def test_contract_fields_on_normal_record
    rec = { 'id' => 4400000000000001, 'created_at' => '2020-05-06T07:08:09+08:00',
            'text' => '合成正文。', 'source_url' => 'https://weibo.example.synthetic/1', 'scope' => 'public',
            'pictures' => [{ 'url' => 'https://img.example.synthetic/w01.jpg', 'alt' => '合成图' }] }
    out = normalize(rec)
    CONTRACT_KEYS.each { |k| assert out.key?(k), "缺少契约字段 #{k}" }
    assert_equal 'weibo', out['source']
    assert_equal '4400000000000001', out['source_id'] # 字符串 ID
    assert_kind_of String, out['source_id']
    assert_equal '2020-05-06T07:08:09+08:00', out['created_at'] # 带时区偏移
    assert_equal 'public', out['visibility']
    assert_nil out['reply_to_source_id']
    assert_nil out['repost']
    assert_equal 1, out['media'].length
    assert_match(/\A[0-9a-f]{64}\z/, out['raw_record_sha256'])
    assert_equal '原偏移', out['extra']['source_tz']
    assert_equal '2020-05-05T23:08:09Z', out['extra']['created_at_utc']
  end

  def test_source_id_string_throughout
    out = normalize('id' => '4400000000000002', 'created_at' => '2019-08-08 08:09:10', 'text' => 'x')
    assert_equal '4400000000000002', out['source_id']
    assert_equal '2019-08-08T08:09:10+08:00', out['created_at']
    assert_equal 'default+08:00', out['extra']['source_tz']
  end

  def test_missing_required_fields_raise_record_error
    n = WeiboImport::Normalize
    assert_raises(n::RecordError) { normalize('created_at' => '2020-01-01 00:00:00', 'text' => 'x') }
    err = assert_raises(n::RecordError) { normalize('id' => '1', 'text' => 'x') }
    assert_includes err.message, '缺少时间字段'
    err2 = assert_raises(n::RecordError) { normalize('id' => '1', 'created_at' => '2020-01-01 00:00:00') }
    assert_includes err2.message, '缺少正文字段'
  end

  def test_bad_time_goes_to_error_not_substituted
    n = WeiboImport::Normalize
    %w[not-a-valid-time 2099-06-06T06:06:06+08:00 2008-12-31T23:59:59+08:00].each do |bad|
      err = assert_raises(n::RecordError, "应拒绝 #{bad}") { normalize('id' => '9', 'created_at' => bad, 'text' => 'x') }
      refute_match(/当前时间|Time\.now/, err.message)
    end
  end

  def test_visibility_mapping_and_default
    assert_equal 'private', normalize('id' => '5', 'created_at' => '2020-05-06T07:10:00+08:00', 'text' => 'r', 'scope' => 'friends', 'reply_to_id' => '4400000000000001')['visibility']
    assert_equal 'direct', normalize('id' => '13', 'created_at' => '2023-01-01T00:00:00+08:00', 'text' => 'm', 'scope' => 'onlyme')['visibility']
    # 缺可见性字段 → default（unlisted）
    assert_equal 'unlisted', normalize('id' => '20', 'created_at' => '2020-05-06T07:08:09+08:00', 'text' => 'd')['visibility']
    err = assert_raises(WeiboImport::Normalize::RecordError) { normalize('id' => '21', 'created_at' => '2020-05-06T07:08:09+08:00', 'text' => 'u', 'scope' => 'secret-level') }
    assert_includes err.message, '未声明的可见性取值'
  end

  def test_reply_and_repost
    out = normalize('id' => '5', 'created_at' => '2020-05-06T07:10:00+08:00', 'text' => '回复', 'scope' => 'friends', 'reply_to_id' => 4400000000000001)
    assert_equal '4400000000000001', out['reply_to_source_id']

    quote = '转' * 250
    out2 = normalize('id' => '4', 'created_at' => '2021-06-06T06:06:06+08:00', 'text' => '转发', 'reposted' => true, 'repost_quote' => quote)
    assert_equal ('转' * 200) + '…', out2['repost'] # 200 字素截断加省略号

    out3 = normalize('id' => '4b', 'created_at' => '2021-06-06T06:06:07+08:00', 'text' => '非转发', 'reposted' => false, 'repost_quote' => quote)
    assert_nil out3['repost']
  end

  def test_raw_record_sha256_uses_original_line_when_given
    rec = { 'id' => '1', 'created_at' => '2020-05-06T07:08:09+08:00', 'text' => 'x' }
    a = normalize(rec, MAP, nil, '{"id":"1"}')
    b = normalize(rec, MAP, nil, '{"id":"1"}') # 相同原始行 → 相同摘要
    c = normalize(rec, MAP, nil, '{"id":"1"} ') # 原始字节不同 → 摘要不同
    d = normalize(rec) # 无 line → canonical json
    assert_equal a['raw_record_sha256'], b['raw_record_sha256']
    assert_equal Digest::SHA256.hexdigest('{"id":"1"}'), a['raw_record_sha256']
    refute_equal a['raw_record_sha256'], c['raw_record_sha256']
    refute_equal a['raw_record_sha256'], d['raw_record_sha256']
  end

  # ---- HTML → 文本 ----

  def test_html_to_text
    map = WeiboImport::Adapter::Map.from_hash(
      'source' => 'weibo', 'id' => { 'field' => 'id' },
      'created_at' => { 'field' => 'created_at' }, 'text' => { 'field' => 'text', 'html' => true }
    )
    html = '<p>第一段</p><p>第二行<br/>续行 &amp; &lt;b&gt;加粗&lt;/b&gt;</p>' \
           '<a href="https://x.example/page">点我</a> <a href="https://x.example/raw">https://x.example/raw</a>' \
           '<img src="https://x.example/i.jpg" alt="配图说明"><script>alert(1)</script>'
    out = normalize({ 'id' => '7', 'created_at' => '2020-05-06T07:08:09+08:00', 'text' => html }, map)
    text = out['text']
    assert_includes text, "第一段\n第二行\n续行 & <b>加粗</b>"
    assert_includes text, '点我 (https://x.example/page)'
    assert_includes text, 'https://x.example/raw' # 链接文字=地址时不重复
    assert_includes text, '【图:配图说明】'
    refute_includes text, '<script' # 标签被剥离；script 主体作为惰性文本保留（绝不执行任何脚本）
  end

  def test_decode_entities_numeric
    assert_equal 'A©中', WeiboImport::Normalize.decode_entities('A&#169;&#x4e2d;')
    assert_equal 'A©中…', WeiboImport::Normalize.decode_entities('A&copy;中&hellip;')
  end

  # ---- read_records / records_from_input ----

  def test_read_records_jsonl_fixture
    payload = WeiboImport::Normalize.read_records(File.join(FIXTURES_DIR, 'synthetic_all.jsonl'))
    assert_equal :jsonl, payload[:format]
    assert_equal 16, payload[:records].length
    assert_equal 16, payload[:sources].compact.length
    assert_empty payload[:parse_errors]
  end

  def test_read_records_badlines
    payload = WeiboImport::Normalize.read_records(File.join(FIXTURES_DIR, 'synthetic_badlines.jsonl'))
    assert_equal :jsonl, payload[:format]
    assert_equal 3, payload[:records].length
    assert_nil payload[:records][1]
    assert_equal 1, payload[:parse_errors].length
    assert_equal 2, payload[:parse_errors][0]['line_no']
  end

  def test_read_records_top_level_array
    payload = WeiboImport::Normalize.read_records(File.join(FIXTURES_DIR, 'synthetic_array.json'))
    assert_equal :json_array, payload[:format]
    assert_equal 2, payload[:records].length
  end

  def test_read_records_wrapped_object_probe
    payload = WeiboImport::Normalize.read_records(File.join(FIXTURES_DIR, 'synthetic_wrapped.json'))
    assert_equal :single_object, payload[:format]
    roots = WeiboImport::Normalize.probe_record_roots(payload[:records].first)
    assert_equal 'data', roots.first['path']
    assert_equal 2, roots.first['count']

    map = WeiboImport::Adapter::Map.from_hash(
      'source' => 'weibo', 'records_root' => 'data', 'id' => { 'field' => 'id' },
      'created_at' => { 'field' => 'created_at' }, 'text' => { 'field' => 'text' }
    )
    expanded = WeiboImport::Normalize.records_from_input(File.join(FIXTURES_DIR, 'synthetic_wrapped.json'), map)
    assert_equal 2, expanded[:records].length

    no_root = WeiboImport::Adapter::Map.from_hash(
      'source' => 'weibo', 'id' => { 'field' => 'id' },
      'created_at' => { 'field' => 'created_at' }, 'text' => { 'field' => 'text' }
    )
    err = assert_raises(ArgumentError) { WeiboImport::Normalize.records_from_input(File.join(FIXTURES_DIR, 'synthetic_wrapped.json'), no_root) }
    assert_includes err.message, 'records_root'
  end

  def test_read_records_missing_file
    assert_raises(ArgumentError) { WeiboImport::Normalize.read_records(File.join(FIXTURES_DIR, 'nope.json')) }
  end

  # ---- 整文件 normalize：错误清单口径 ----

  def test_normalize_full_fixture_error_breakdown
    payload = WeiboImport::Normalize.records_from_input(File.join(FIXTURES_DIR, 'synthetic_all.jsonl'), MAP)
    ok = 0
    errors = []
    payload[:records].each_with_index do |rec, idx|
      if rec.nil?
        errors << ['json_parse_error', idx]
        next
      end
      begin
        WeiboImport::Normalize.normalize_record(rec, MAP, index: idx, original_line: payload[:sources][idx])
        ok += 1
      rescue WeiboImport::Normalize::RecordError => e
        errors << [e.message.sub(/:.*\z/, ''), idx]
      end
    end
    assert_equal 12, ok
    assert_equal 4, errors.length
    reasons = errors.map(&:first)
    assert_equal 1, reasons.count('无法解析时间')
    assert_equal 1, reasons.count('未来时间（超出 24h 容差）')
    assert_equal 1, reasons.count('时间早于 2009-01-01（疑似数据异常）')
    assert_equal 1, reasons.count { |r| r.start_with?('缺少正文字段') } # 消息含字段名引号，无冒号不被裁剪
  end

  # ---- 字素与截断 ----

  def test_grapheme_count_and_truncate
    n = WeiboImport::Normalize
    assert_equal 5, n.grapheme_count('abcde')
    assert_equal 4, n.grapheme_count('中文字素') # emoji 组合按一个字素
    assert_equal 3, n.grapheme_count('👩‍👩‍👧‍👦ab') # ZWJ 家庭 emoji = 1 字素 + 2 字母
    assert_equal 'ab…', n.truncate_graphemes('abcdef', 2)
    assert_equal 'abcdef', n.truncate_graphemes('abcdef', 10)
    assert_equal '', n.truncate_graphemes(nil, 3)
  end
end
