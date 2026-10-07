# frozen_string_literal: true

require 'weibo_import/report'
require 'weibo_import/splitter'

class ReportTest < Minitest::Test
  def nrec(sid:, created_at:, text: '正文', visibility: 'public', media: [], reply: nil, repost: nil)
    { 'source' => 'weibo', 'source_id' => sid, 'source_url' => nil, 'created_at' => created_at,
      'text' => text, 'visibility' => visibility, 'media' => media,
      'reply_to_source_id' => reply, 'repost' => repost, 'raw_record_sha256' => '0' * 64, 'extra' => {} }
  end

  def img
    { 'url' => 'https://img.example.synthetic/w.jpg', 'path' => nil, 'description' => nil }
  end

  def test_plan_stats_basic_counts
    records = [
      nrec(sid: '1', created_at: '2020-01-01T00:00:00+08:00'),
      nrec(sid: '2', created_at: '2021-06-01T00:00:00+08:00', reply: '1'),
      nrec(sid: '3', created_at: '2022-01-01T00:00:00+08:00', repost: '转发摘要'),
      nrec(sid: '4', created_at: '2023-01-01T00:00:00+08:00', visibility: 'private'),
      nrec(sid: '1', created_at: '2020-02-01T00:00:00+08:00') # 重复
    ]
    stats = WeiboImport::Report.plan_stats(records)
    assert_equal 5, stats['total']
    assert_equal 1, stats['duplicates']
    assert_equal Time.iso8601('2020-01-01T00:00:00+08:00'), stats['earliest']
    assert_equal Time.iso8601('2023-01-01T00:00:00+08:00'), stats['latest']
    assert_equal 3, stats['originals'] # 1,2? 见下：2 是回复、3 是转发 → 原创 = 1,1(dup),4
    assert_equal 1, stats['reposts']
    assert_equal 1, stats['replies']
    assert_equal 1, stats['non_public']
    assert stats['anomalies'].any? { |a| a['reason'].include?('重复') }
  end

  def test_plan_stats_media_and_projection
    records = [
      nrec(sid: '9img', created_at: '2020-01-01T00:00:00+08:00', text: '九图', media: Array.new(9) { |i| { 'url' => "https://img.example.synthetic/g#{i}.jpg", 'path' => nil, 'description' => nil } }),
      nrec(sid: 'miss', created_at: '2020-01-02T00:00:00+08:00', media: [{ 'url' => nil, 'path' => nil, 'description' => nil }]),
      nrec(sid: 'plain', created_at: '2020-01-03T00:00:00+08:00')
    ]
    stats = WeiboImport::Report.plan_stats(records)
    assert_equal 10, stats['media_images'] # 9 + 缺 URL 项按图片计
    assert_equal 0, stats['media_videos']
    assert_equal 1, stats['media_missing']
    assert_equal 9, stats['media_pending_fetch'] # 有 URL 无本地文件
    assert_equal 0, stats['media_ready']
    # 拆分后：九图 3 帖 + miss 1 帖 + plain 1 帖 = 5
    assert_equal 5, stats['projected_statuses']
    assert_equal 1, stats['overlong'] # 九图触发拆分
  end

  def test_plan_stats_limit_counts_source_records
    records = Array.new(3) { |i| nrec(sid: i.to_s, created_at: '2020-01-01T00:00:00+08:00') }
    stats = WeiboImport::Report.plan_stats(records, limit: 2)
    assert_equal 2, stats['total'] # --limit 语义 = 来源微博条数，不是拆分后帖子数
  end

  def test_plan_report_rendering
    stats = WeiboImport::Report.plan_stats([nrec(sid: '1', created_at: '2020-01-01T00:00:00+08:00')])
    text = WeiboImport::Report.plan_report(stats, account: 'me', visibility: 'unlisted', limit: 20, batch: 'B001')
    assert_includes text, '目标账号: me'
    assert_includes text, '拆分后预计创建帖子数'
    assert_includes text, '计数口径说明'
    assert_includes text, '--limit 语义'
    assert_includes text, '来源微博总数 | 1'
  end

  def test_normalize_summary_renders
    s = { format: :jsonl, read: 16, ok: 12, errors: 4, error_breakdown: { '无法解析时间' => 1 },
          media_items: 14, media_with_url: 13, media_with_path: 0, raw_dir: 'raw_copy/', out: 'normalized.jsonl', errors_out: 'errors.jsonl' }
    text = WeiboImport::Report.normalize_summary(s)
    assert_includes text, '读取记录        : 16'
    assert_includes text, '成功规范化      : 12'
    assert_includes text, '错误记录        : 4'
    assert_includes text, '无法解析时间=1'
  end
end
