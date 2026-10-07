# frozen_string_literal: true

require 'weibo_import/id_allocator'

class IdAllocatorTest < Minitest::Test
  IA = WeiboImport::IdAllocator

  def test_pack_unpack_roundtrip
    id = IA.pack(1_587_128_890_000, 123)
    assert_equal 1_587_128_890_000, id >> IA::TIMESTAMP_SHIFT
    assert_equal [1_587_128_890_000, 123], IA.unpack(id)
    assert_equal Time.at(1_587_128_890).utc, IA.id_to_time(id)
  end

  def test_sequence_strictly_increases_within_same_ms
    a = IA::Allocator.new
    ms = 1_587_128_890_000
    ids = Array.new(5) { a.next_id_at(ms) }
    assert_equal ids, ids.sort
    assert_equal ids.uniq, ids
    assert_equal ms, a.last_ms
    assert_equal 4, a.last_seq
  end

  def test_sequence_resets_on_new_ms
    a = IA::Allocator.new
    id1 = a.next_id_at(1_587_128_890_000)
    id2 = a.next_id_at(1_587_128_890_001)
    assert id2 > id1
    assert_equal 0, a.last_seq
    assert_equal 1_587_128_890_001, a.last_ms
  end

  def test_backwards_ms_clamped_to_last_ms
    a = IA::Allocator.new
    id1 = a.next_id_at(1_587_128_890_005)
    id2 = a.next_id_at(1_587_128_890_001) # 时间倒退：钳制到 last_ms，绝不产生更小 ID
    assert id2 > id1
    assert_equal 1_587_128_890_005, a.last_ms
    # 钳制后 (ms, seq) 仍在同毫秒内继续递增
    ms, seq = IA.unpack(id2)
    assert_equal 1_587_128_890_005, ms
    assert_equal 1, seq
  end

  def test_parent_before_child_across_mixed_times
    a = IA::Allocator.new
    # 父段 07:08:09，子段（媒体续帖）同一毫秒；随后插入一条更早时间的记录
    parent = a.next_id_at(1_587_128_890_000)
    child = a.next_id_at(1_587_128_890_000)
    earlier = a.next_id_at(1_587_128_889_000) # 更早的来源时间
    assert parent < child
    assert earlier > child # 钳制保证单调不减
    assert_equal [parent, child, earlier].sort, [parent, child, earlier]
  end

  def test_reserve_skips_occupied_ms_seq
    a = IA::Allocator.new
    ms = 1_587_128_890_000
    a.reserve(IA.pack(ms, 0))
    a.reserve(IA.pack(ms, 1))
    id = a.next_id_at(ms)
    _used_ms, seq = IA.unpack(id)
    assert_equal 2, seq # 跳过已登记的 0、1
  end

  def test_reserve_updates_high_water
    a = IA::Allocator.new
    a.next_id_at(1_000)
    a.reserve(IA.pack(5_000, 7))
    assert_equal 5_000, a.last_ms
    id = a.next_id_at(4_000) # 倒退也被钳制
    assert id > IA.pack(5_000, 7)
  end

  def test_exhaustion_raises
    a = IA::Allocator.new(timestamp_shift: 4) # 16 个序列/毫秒
    ms = 1_000_000
    16.times { a.next_id_at(ms) }
    assert_raises(IA::ExhaustedError) { a.next_id_at(ms) }
    # 新毫秒恢复
    id = a.next_id_at(ms + 1)
    assert_equal ms + 1, a.last_ms
  end

  def test_collision_detection
    ids = [IA.pack(1, 0), IA.pack(1, 1), IA.pack(1, 0)]
    assert IA.detect_collision?(ids)
    assert_equal [IA.pack(1, 0)], IA.collision_pairs(ids)
    refute IA.detect_collision?([IA.pack(1, 0), IA.pack(1, 1)])
    assert_empty IA.collision_pairs([1, 2, 3])
  end
end
