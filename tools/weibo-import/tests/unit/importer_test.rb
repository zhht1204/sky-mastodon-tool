# frozen_string_literal: true

require 'weibo_import/importer'
require 'tmpdir'

class ImporterTest < Minitest::Test
  I = WeiboImport::Importer

  def test_sort_records_parent_first_and_stable
    a = { 'source_id' => '2', 'created_at' => '2012-08-28T21:11:41+08:00' }
    b = { 'source_id' => '1', 'created_at' => '2012-08-28T21:11:41+08:00' } # 同时间按 id
    c = { 'source_id' => '9', 'created_at' => '2012-08-27T00:00:00+08:00' } # 更早
    assert_equal [c['source_id'], b['source_id'], a['source_id']], I.sort_records([a, b, c]).map { |r| r['source_id'] }
  end

  def test_source_ms_matches_snowflake_time_bits
    str = '2012-08-28T21:11:41+08:00'
    ms = I.source_ms(str)
    assert_equal (Time.parse(str).utc.to_f * 1000).to_i, ms
    assert_equal Time.at(ms / 1000.0).utc.iso8601, '2012-08-28T13:11:41Z'
  end

  def test_resolve_media_path_prefers_existing_local_path
    Dir.mktmpdir do |dir|
      f = File.join(dir, 'a.jpg')
      File.write(f, 'x')
      path, missing = I.resolve_media_path(dir, { 'path' => f, 'url' => nil })
      assert_equal f, path
      refute missing
    end
  end

  def test_resolve_media_path_uses_download_naming_for_url
    Dir.mktmpdir do |dir|
      url = 'https://ww1.sinaimg.cn/large/96bc6007jw1eifniz12whj205k05kmx.jpg'
      expected = File.join(dir, WeiboImport::Downloader.filename_from_uri(URI.parse(url)))
      File.write(expected, 'x')
      path, missing = I.resolve_media_path(dir, { 'path' => nil, 'url' => url })
      assert_equal expected, path
      refute missing

      File.delete(expected)
      path2, missing2 = I.resolve_media_path(dir, { 'path' => nil, 'url' => url })
      assert_nil path2
      assert missing2
    end
  end

  def test_resolve_media_path_missing_when_local_absent_and_no_url
    path, missing = I.resolve_media_path('/nonexistent', { 'path' => '/nonexistent/x.jpg', 'url' => nil })
    assert_nil path
    assert missing
  end

  def test_precheck_states
    h = 'a' * 64
    assert_equal :new, I.precheck([], h)
    assert_equal :skip, I.precheck([{ 'normalized_hash' => h, 'state' => 'imported' }], h)
    assert_equal :partial_skip, I.precheck([{ 'normalized_hash' => h, 'state' => 'partial' }], h)
    assert_equal :conflict, I.precheck([{ 'normalized_hash' => 'b' * 64, 'state' => 'imported' }], h)
  end

  def test_build_segments_appends_source_url_to_first_post_within_budget
    rec = { 'text' => '短正文', 'media' => [], 'created_at' => '2012-08-28T21:11:41+08:00',
            'source_url' => 'https://weibo.com/1000000001/SynPost01' }
    segs = I.build_segments(rec)
    assert_equal 1, segs.length
    assert segs[0]['text'].end_with?("\nhttps://weibo.com/1000000001/SynPost01")
    assert_operator WeiboImport::Splitter.weighted_length(segs[0]['text']), :<=, 500
  end

  def test_build_segments_long_text_keeps_url_on_first_post
    rec = { 'text' => '很长的句子。' * 120, 'media' => [], 'created_at' => '2012-08-28T21:11:41+08:00',
            'source_url' => 'https://weibo.com/1000000001/SynPost01' }
    segs = I.build_segments(rec)
    assert_operator segs.length, :>=, 2
    assert segs[0]['text'].end_with?('https://weibo.com/1000000001/SynPost01')
    segs[1..].each { |s| refute s['text'].include?('SynPost01') }
    segs.each { |s| assert_operator WeiboImport::Splitter.weighted_length(s['text']), :<=, 500 }
  end

  def test_build_segments_no_url_no_suffix
    segs = I.build_segments('text' => '正文', 'media' => [], 'created_at' => '2012-08-28T21:11:41+08:00', 'source_url' => nil)
    assert_equal '正文', segs[0]['text']
  end

  def test_summary_counts_shape
    ctx = { counters: { complete: 1, partial: 0, failed: 0, skipped: 2, skipped_partial: 0, conflicts: 0,
                        statuses: 3, media: 4, orphan_media_cleaned: 0 },
            partial: [], failures: [], map_out: 'import-map-x.jsonl' }
    text = I.summary(ctx, 3)
    assert_includes text, '完整导入        : 1'
    assert_includes text, '创建帖子数      : 3'
    assert_includes text, 'import-map-x.jsonl'
  end
end
