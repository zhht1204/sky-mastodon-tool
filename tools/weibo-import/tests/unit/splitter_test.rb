# frozen_string_literal: true

require 'weibo_import/normalize'
require 'weibo_import/splitter'

class SplitterTest < Minitest::Test
  S = WeiboImport::Splitter

  def rec(text:, media: [], created_at: '2020-05-06T07:08:09+08:00')
    { 'source' => 'weibo', 'source_id' => '1', 'created_at' => created_at, 'text' => text,
      'visibility' => 'unlisted', 'media' => media, 'reply_to_source_id' => nil, 'repost' => nil }
  end

  def img(i)
    { 'url' => "https://img.example.synthetic/w#{i}.jpg", 'path' => nil, 'description' => nil }
  end

  def video
    { 'url' => 'https://img.example.synthetic/v.mp4', 'path' => nil, 'description' => nil }
  end

  # ---- weighted_length ----

  def test_weighted_length_plain_text
    assert_equal 0, S.weighted_length('')
    assert_equal 5, S.weighted_length('abcde')
    assert_equal 3, S.weighted_length('一二三') # 3 个 CJK 字素
  end

  def test_weighted_length_url_weighted
    url = 'https://example.synthetic/a/long/path'
    assert_equal S::URL_WEIGHT, S.weighted_length(url)
    assert_equal 1 + S::URL_WEIGHT, S.weighted_length("看#{url}")
    assert_equal (2 * S::URL_WEIGHT) + 1, S.weighted_length("#{url} #{url}") # 中间 1 个空格按字素计
    assert_equal 2 + 4, S.weighted_length("看看#{url}", url_weight: 4) # 2 字素 + 自定义权重 4
  end

  # ---- split_text 边界 ----

  def test_split_short_text_single_segment
    segs = S.split_text('短正文。')
    assert_equal 1, segs.length
    assert_equal '短正文。', segs[0]['text']
    refute segs[0]['overlong']
  end

  def test_split_empty_text
    assert_empty S.split_text('')
    assert_empty S.split_text('   ')
    assert_empty S.split_text(nil)
  end

  def test_split_paragraph_boundary
    paras = Array.new(15) { |i| "第#{i}段合成样本正文，凑足足够的加权长度用来触发跨段拆分边界验证逻辑。" }
    text = paras.join("\n\n")
    segs = S.split_text(text)
    assert_operator segs.length, :>, 1
    segs.each do |seg|
      assert_operator S.weighted_length(seg['text']), :<=, S::DEFAULT_MAX_CHARS
      refute seg['overlong']
    end
    # 不丢内容、不伪造编号：拼接（按段）后字素总数不增
    joined = segs.map { |s| s['text'] }.join
    orig_graphemes = text.strip.scan(/\X/).reject { |c| c == "\n" }.length
    assert_equal orig_graphemes, joined.scan(/\X/).reject { |c| c == "\n" }.length
  end

  def test_split_sentence_boundary
    text = ('一句话样本用于验证句读边界拆分。' * 40)
    segs = S.split_text(text)
    assert_operator segs.length, :>, 1
    segs.each { |seg| assert_operator S.weighted_length(seg['text']), :<=, S::DEFAULT_MAX_CHARS }
  end

  def test_split_never_breaks_url
    long_text = ('铺垫句子。' * 100) + 'https://example.synthetic/very/long/path?query=1'
    segs = S.split_text(long_text)
    joined = segs.map { |s| s['text'] }.join
    assert_includes joined, 'https://example.synthetic/very/long/path?query=1' # URL 完整保留
    segs.each do |seg|
      seg['text'].scan(%r{https?://\S+}).each do |u|
        assert_operator u.length, :>, 10 # URL 原子未被切碎
      end
    end
  end

  def test_overlong_url_never_cut_and_weighted_as_single_link
    url = "https://example.synthetic/#{'a' * 600}"
    segs = S.split_text("前奏。#{url}")
    # URL 按固定权重 23 计入加权长度（Mastodon 链接加权），不会因字符数超限被切碎
    assert_equal 1, segs.length
    assert_equal "前奏。#{url}", segs[0]['text']
    refute segs[0]['overlong']
    assert_equal 3 + S::URL_WEIGHT, S.weighted_length(segs[0]['text'])
  end

  def test_hard_cut_by_graphemes_when_no_boundary
    text = '无' * 1200
    segs = S.split_text(text)
    assert_equal 3, segs.length # 500 + 500 + 200
    assert_equal '无' * 500, segs[0]['text']
    assert_equal '无' * 200, segs[2]['text']
  end

  # ---- media_units ----

  def test_media_units_groups_of_four
    units = S.media_units((1..9).map { |i| img(i) })
    assert_equal [4, 4, 1], units.map(&:length) # 九图 → 4+4+1，保序
    assert_equal (1..9).map { |i| img(i) }, units.flatten
  end

  def test_media_units_video_separate
    units = S.media_units([img(1), img(2), video, img(3)])
    assert_equal [[img(1), img(2)], [video], [img(3)]], units
  end

  def test_media_units_drops_invalid_items
    units = S.media_units([{ 'url' => nil, 'path' => nil }, img(1), 'not-a-hash'])
    assert_equal [[img(1)]], units
  end

  # ---- segments（拆分后帖子形态）----

  def test_segments_simple_post
    segs = S.segments(rec(text: '普通帖子。', media: [img(1)]))
    assert_equal 1, segs.length
    assert_equal 0, segs[0]['segment_no']
    assert_nil segs[0]['parent_segment_no']
    assert_equal [img(1)], segs[0]['media']
    assert_equal '2020-05-06T07:08:09+08:00', segs[0]['created_at']
  end

  def test_segments_nine_images_three_posts
    segs = S.segments(rec(text: '九图帖。', media: (1..9).map { |i| img(i) }))
    assert_equal 3, segs.length
    assert_equal '九图帖。', segs[0]['text']
    assert_equal 4, segs[0]['media'].length # 首组随首段
    assert_equal '', segs[1]['text'] # 其余各组纯媒体续帖
    assert_equal 4, segs[1]['media'].length
    assert_equal 1, segs[2]['media'].length
    assert_equal [nil, 0, 1], segs.map { |s| s['parent_segment_no'] } # 父段在前、链式 reply
    assert_equal [0, 1, 2], segs.map { |s| s['segment_no'] }
    segs.each { |s| assert_equal '2020-05-06T07:08:09+08:00', s['created_at'] } # 同一 created_at
  end

  def test_segments_video_and_images
    segs = S.segments(rec(text: '视频混图。', media: [video, img(1), img(2)]))
    assert_equal 2, segs.length
    assert_equal [video], segs[0]['media'] # 保序：视频在首段
    assert_equal [img(1), img(2)], segs[1]['media']
  end

  def test_segments_overlong_text_media_on_first
    text = ('长段落样本正文。' * 80)
    segs = S.segments(rec(text: text, media: [img(1), img(2)]))
    assert_operator segs.length, :>, 1
    assert_equal [img(1), img(2)], segs[0]['media']
    segs.drop(1).each { |s| assert_empty s['media'] }
  end

  def test_segments_media_only_without_text
    segs = S.segments(rec(text: '', media: (1..5).map { |i| img(i) }))
    assert_equal 2, segs.length
    assert_equal 4, segs[0]['media'].length
    assert_equal 1, segs[1]['media'].length
    segs.each { |s| assert_equal '', s['text'] }
  end

  def test_segments_empty_post_fallback
    segs = S.segments(rec(text: '', media: []))
    assert_equal 1, segs.length
    assert_equal '', segs[0]['text']
    assert_empty segs[0]['media']
  end

  def test_video_detection
    assert S.video?({ 'url' => 'https://x.example/a.MP4?x=1' })
    assert S.video?({ 'path' => 'media/clip.mov' })
    refute S.video?({ 'url' => 'https://x.example/a.jpg' })
    refute S.video?({ 'url' => nil, 'path' => nil })
  end
end
