# frozen_string_literal: true

require 'weibo_import/adapter'

class AdapterTest < Minitest::Test
  BASE_MAP = {
    'source' => 'weibo',
    'id' => { 'field' => 'id' },
    'created_at' => { 'field' => 'created_at', 'timezone' => 'Asia/Shanghai' },
    'text' => { 'field' => 'text', 'html' => false }
  }.freeze

  def build_map(overrides = {})
    merged = BASE_MAP.merge(overrides)
    WeiboImport::Adapter::Map.from_hash(WeiboImport::Adapter.deep_stringify(merged))
  end

  # ---- dig / deep_stringify ----

  def test_dig_nested_and_array_index
    rec = { 'mblog' => { 'pics' => [{ 'url' => 'https://x.example/a.jpg' }, { 'url' => 'https://x.example/b.jpg' }] } }
    assert_equal 'https://x.example/a.jpg', WeiboImport::Adapter.dig(rec, 'mblog.pics.0.url')
    assert_equal 'https://x.example/b.jpg', WeiboImport::Adapter.dig(rec, 'mblog.pics.1.url')
  end

  def test_dig_miss_returns_nil
    rec = { 'a' => { 'b' => 1 } }
    assert_nil WeiboImport::Adapter.dig(rec, 'a.x')
    assert_nil WeiboImport::Adapter.dig(rec, '')
    assert_nil WeiboImport::Adapter.dig(rec, nil)
    assert_nil WeiboImport::Adapter.dig(rec, 'a.b.c')
  end

  def test_deep_stringify_symbol_keys
    h = WeiboImport::Adapter.deep_stringify({ id: { field: 'id' }, list: [{ u: 1 }] })
    assert_equal({ 'id' => { 'field' => 'id' }, 'list' => [{ 'u' => 1 }] }, h)
  end

  # ---- Map 校验 ----

  def test_valid_map_loads_from_fixture_yaml
    map = WeiboImport::Adapter::Map.load(File.join(FIXTURES_DIR, 'field_map.synthetic.yml'))
    assert_equal 'weibo', map.source
    assert_equal 'id', map.id_field
    assert_equal 'Asia/Shanghai', map.timezone
    assert_equal 'pictures', map.media_list_field
    assert_equal({ 'url' => 'url', 'path' => 'local_path', 'description' => 'alt' }, map.media_cfg)
  end

  def test_missing_required_fields_raises
    e = assert_raises(WeiboImport::Adapter::MapError) { build_map('id' => { 'field' => '' }) }
    assert_includes e.message, 'id.field 必填'
  end

  def test_invalid_timezone_format_raises
    e = assert_raises(WeiboImport::Adapter::MapError) do
      build_map('created_at' => { 'field' => 'created_at', 'timezone' => 'Mars/Olympus' })
    end
    assert_includes e.message, 'timezone 非法'
  end

  def test_visibility_relaxation_rejected
    vis = { 'field' => 'scope', 'default' => 'unlisted', 'mapping' => { 'friends' => 'public' }, 'strictness' => { 'friends' => 2 } }
    e = assert_raises(WeiboImport::Adapter::MapError) { build_map('visibility' => vis) }
    assert_includes e.message, '放宽了可见性'
  end

  def test_visibility_strictness_same_rank_allowed
    vis = { 'field' => 'scope', 'default' => 'unlisted', 'mapping' => { 'friends' => 'private' }, 'strictness' => { 'friends' => 2 } }
    assert_kind_of WeiboImport::Adapter::Map, build_map('visibility' => vis)
  end

  def test_visibility_default_must_be_known
    vis = { 'field' => 'scope', 'default' => 'followers' }
    e = assert_raises(WeiboImport::Adapter::MapError) { build_map('visibility' => vis) }
    assert_includes e.message, 'visibility.default 非法'
  end

  # ---- extract ----

  def test_extract_integer_id_becomes_string
    map = build_map
    ex = map.extract('id' => 4400000000000001, 'created_at' => '2020-05-06T07:08:09+08:00', 'text' => '合成')
    assert_equal '4400000000000001', ex.source_id
    assert_kind_of String, ex.source_id
    assert_equal '合成', ex.text_raw
  end

  def test_extract_blank_id_becomes_nil
    ex = build_map.extract('id' => '   ', 'created_at' => '2020-05-06T07:08:09+08:00', 'text' => 'x')
    assert_nil ex.source_id
  end

  def test_extract_media_items_from_list
    map = build_map('media' => { 'list_field' => 'pictures', 'url_field' => 'url', 'path_field' => 'local_path', 'description_field' => 'alt' })
    ex = map.extract('id' => '1', 'created_at' => '2020-01-01 00:00:00', 'text' => 't',
                     'pictures' => [{ 'url' => 'https://x.example/a.jpg', 'alt' => '合成图' }, 'https://x.example/b.jpg'])
    assert_equal [{ 'url' => 'https://x.example/a.jpg', 'path' => nil, 'description' => '合成图' },
                  { 'url' => 'https://x.example/b.jpg', 'path' => nil, 'description' => nil }], ex.media_items
    assert_nil ex.media_error
  end

  def test_extract_media_list_not_array_sets_error
    map = build_map('media' => { 'list_field' => 'pictures' })
    ex = map.extract('id' => '1', 'created_at' => '2020-01-01 00:00:00', 'text' => 't', 'pictures' => 'not-array')
    assert_nil ex.media_items
    assert_includes ex.media_error, '不是数组'
  end

  # ---- records_root ----

  def test_records_of_with_root
    map = build_map('records_root' => 'data')
    top = { 'meta' => { 'x' => 1 }, 'data' => [{ 'id' => '1' }, { 'id' => '2' }] }
    assert_equal 2, map.records_of(top).length
  end

  def test_records_of_root_miss_raises
    map = build_map('records_root' => 'missing.path')
    e = assert_raises(WeiboImport::Adapter::MapError) { map.records_of({ 'meta' => {} }) }
    assert_includes e.message, '未命中数组'
  end

  def test_records_of_empty_root_returns_self_array
    map = build_map
    assert_equal [{ 'id' => '1' }], map.records_of({ 'id' => '1' })
  end

  # ---- repost 判定（唯一实现在 Adapter::Map#repost_flag）----

  def test_repost_flag_nonempty_hash_is_repost
    map = build_map('repost' => { 'field' => 'retweet' })
    assert map.repost_flag({ 'id' => '9', 'text' => '原文' })
  end

  def test_repost_flag_empty_hash_or_array_is_not_repost
    map = build_map('repost' => { 'field' => 'retweet' })
    refute map.repost_flag({})
    refute map.repost_flag([])
    refute map.repost_flag(nil)
  end

  def test_repost_flag_scalar_uses_truthy_list
    map = build_map('repost' => { 'field' => 'is_rt', 'truthy' => [true, 1, 'true', '1'] })
    assert map.repost_flag(true)
    assert map.repost_flag('1')
    refute map.repost_flag(false)
    refute map.repost_flag(0)
  end

  # ---- source_url 模板拼接 ----

  def test_source_url_template_interpolation
    map = build_map('source_url' => { 'template' => 'https://weibo.com/{userId}/{mblogid}' })
    ex = map.extract('id' => '1', 'created_at' => '2020-01-01 00:00:00', 'text' => 't',
                     'userId' => '1000000001', 'mblogid' => 'SynPost01')
    assert_equal 'https://weibo.com/1000000001/SynPost01', ex.source_url
  end

  def test_source_url_field_takes_precedence_over_template
    map = build_map('source_url' => { 'field' => 'link', 'template' => 'https://weibo.com/{userId}/{mblogid}' })
    ex = map.extract('id' => '1', 'created_at' => '2020-01-01 00:00:00', 'text' => 't',
                     'link' => 'https://weibo.com/1/abc', 'userId' => '2', 'mblogid' => 'x')
    assert_equal 'https://weibo.com/1/abc', ex.source_url
  end

  # ---- 转发引用模板与截断上限 ----

  def test_quote_template_composes_from_multiple_fields
    map = build_map('repost' => { 'field' => 'retweet', 'quote_template' => '转发 @{retweet.user.name}: {retweet.text}' })
    ex = map.extract('id' => '1', 'created_at' => '2020-01-01 00:00:00', 'text' => 't',
                     'retweet' => { 'text' => '原文内容', 'user' => { 'name' => '合成作者' } })
    assert_equal '转发 @合成作者: 原文内容', ex.repost_quote_raw
  end

  def test_quote_template_missing_paths_become_empty
    map = build_map('repost' => { 'field' => 'retweet', 'quote_template' => '转发 @{retweet.user.name}: {retweet.text}' })
    ex = map.extract('id' => '1', 'created_at' => '2020-01-01 00:00:00', 'text' => 't',
                     'retweet' => { 'text' => '原文' })
    assert_equal '转发 @: 原文', ex.repost_quote_raw
  end

  def test_quote_max_configurable_and_zero_disables
    map200 = build_map('repost' => { 'field' => 'retweet', 'quote_field' => 'retweet.text' })
    assert_equal 200, map200.repost_quote_max
    map0 = build_map('repost' => { 'field' => 'retweet', 'quote_field' => 'retweet.text', 'quote_max' => 0 })
    assert_equal 0, map0.repost_quote_max
  end

  def test_quote_not_extracted_when_not_repost
    map = build_map('repost' => { 'field' => 'retweet', 'quote_field' => 'retweet.text' })
    ex = map.extract('id' => '1', 'created_at' => '2020-01-01 00:00:00', 'text' => 't', 'retweet' => nil)
    assert_nil ex.repost_quote_raw
  end
end
