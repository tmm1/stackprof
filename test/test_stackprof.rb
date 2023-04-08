$:.unshift File.expand_path('../../lib', __FILE__)
require 'stackprof'
require 'minitest/autorun'
require 'tempfile'
require 'pathname'

class StackProfTest < MiniTest::Test
  def setup
    Object.new # warm some caches to avoid flakiness
  end

  def teardown
    StackProf::Tag.clear
  end

  def test_info
    profile = StackProf.run{}
    assert_equal 1.3, profile[:version]
    assert_equal :wall, profile[:mode]
    assert_equal 1000, profile[:interval]
    assert_equal 0, profile[:samples]
  end

  def test_running
    assert_equal false, StackProf.running?
    StackProf.run{ assert_equal true, StackProf.running? }
  end

  def test_start_stop_results
    assert_nil StackProf.results
    assert_equal true, StackProf.start
    assert_equal false, StackProf.start
    assert_equal true, StackProf.running?
    assert_nil StackProf.results
    assert_equal true, StackProf.stop
    assert_equal false, StackProf.stop
    assert_equal false, StackProf.running?
    assert_kind_of Hash, StackProf.results
    assert_nil StackProf.results
  end

  def test_object_allocation
    profile_base_line = __LINE__+1
    profile = StackProf.run(mode: :object) do
      Object.new
      Object.new
    end
    assert_equal :object, profile[:mode]
    assert_equal 1, profile[:interval]
    if RUBY_VERSION >= '3'
      assert_equal 4, profile[:samples]
    else
      assert_equal 2, profile[:samples]
    end

    frame = profile[:frames].values.first
    assert_includes frame[:name], "StackProfTest#test_object_allocation"
    assert_equal 2, frame[:samples]
    assert_includes [profile_base_line - 2, profile_base_line], frame[:line]
    if RUBY_VERSION >= '3'
      assert_equal [2, 1], frame[:lines][profile_base_line+1]
      assert_equal [2, 1], frame[:lines][profile_base_line+2]
    else
      assert_equal [1, 1], frame[:lines][profile_base_line+1]
      assert_equal [1, 1], frame[:lines][profile_base_line+2]
    end
    frame = profile[:frames].values[1] if RUBY_VERSION < '2.3'

    if RUBY_VERSION >= '3'
      assert_equal [4, 0], frame[:lines][profile_base_line]
    else
      assert_equal [2, 0], frame[:lines][profile_base_line]
    end
  end

  def test_object_allocation_interval
    profile = StackProf.run(mode: :object, interval: 10) do
      100.times { Object.new }
    end
    assert_equal 10, profile[:samples]
  end

  def test_cputime
    profile = StackProf.run(mode: :cpu, interval: 500) do
      math
    end

    assert_operator profile[:samples], :>=, 1
    if RUBY_VERSION >= '3'
      assert profile[:frames].values.take(2).map { |f|
        f[:name].include? "StackProfTest#math"
      }.any?
    else
      frame = profile[:frames].values.first
      assert_includes frame[:name], "StackProfTest#math"
    end
  end

  def test_walltime
    profile = StackProf.run(mode: :wall) do
      idle
    end

    frame = profile[:frames].values.first
    if RUBY_VERSION >= '3'
      assert_equal "IO.select", frame[:name]
    else
      assert_equal "StackProfTest#idle", frame[:name]
    end
    assert_in_delta 200, frame[:samples], 25
  end

  def test_custom
    profile_base_line = __LINE__+1
    profile = StackProf.run(mode: :custom) do
      10.times do
        StackProf.sample
      end
    end

    assert_equal :custom, profile[:mode]
    assert_equal 10, profile[:samples]

    offset = RUBY_VERSION >= '3' ? 1 : 0
    frame = profile[:frames].values[offset]
    assert_includes frame[:name], "StackProfTest#test_custom"
    assert_includes [profile_base_line-2, profile_base_line+1], frame[:line]

    if RUBY_VERSION >= '3'
      assert_equal [10, 0], frame[:lines][profile_base_line+2]
    else
      assert_equal [10, 10], frame[:lines][profile_base_line+2]
    end
  end

  def test_raw
    before_monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC, :microsecond)

    profile = StackProf.run(mode: :custom, raw: true) do
      10.times do
        StackProf.sample
        sleep 0.0001
      end
    end

    after_monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC, :microsecond)

    raw = profile[:raw]
    assert_equal 10, raw[-1]
    assert_equal raw[0] + 2, raw.size

    offset = RUBY_VERSION >= '3' ? -3 : -2
    assert_includes profile[:frames][raw[offset]][:name], 'StackProfTest#test_raw'

    assert_equal 10, profile[:raw_sample_timestamps].size
    profile[:raw_sample_timestamps].each_cons(2) do |t1, t2|
      assert_operator t1, :>, before_monotonic
      assert_operator t2, :>=, t1
      assert_operator t2, :<, after_monotonic
    end

    assert_equal 10, profile[:raw_timestamp_deltas].size
    total_duration = after_monotonic - before_monotonic
    assert_operator profile[:raw_timestamp_deltas].inject(&:+), :<, total_duration

    profile[:raw_timestamp_deltas].each do |delta|
      assert_operator delta, :>, 0
    end
  end

  def test_metadata
    metadata = {
      path: '/foo/bar',
      revision: '5c0b01f1522ae8c194510977ae29377296dd236b',
    }
    profile = StackProf.run(mode: :cpu, metadata: metadata) do
      math
    end

    assert_equal metadata, profile[:metadata]
  end

  def test_empty_metadata
    profile = StackProf.run(mode: :cpu) do
      math
    end

    assert_equal({}, profile[:metadata])
  end

  def test_raises_if_metadata_is_not_a_hash
    exception = assert_raises ArgumentError do
      StackProf.run(mode: :cpu, metadata: 'foobar') do
        math
      end
    end

    assert_equal 'metadata should be a hash', exception.message
  end

  def test_fork
    StackProf.run do
      pid = fork do
        exit! StackProf.running?? 1 : 0
      end
      Process.wait(pid)
      assert_equal 0, $?.exitstatus
      assert_equal true, StackProf.running?
    end
  end

  def foo(n = 10)
    if n == 0
      StackProf.sample
      return
    end
    foo(n - 1)
  end

  def test_recursive_total_samples
    profile = StackProf.run(mode: :cpu, raw: true) do
      10.times do
        foo
      end
    end

    frame = profile[:frames].values.find do |frame|
      frame[:name] == "StackProfTest#foo"
    end
    assert_equal 10, frame[:total_samples]
  end

  def test_gc
    profile = StackProf.run(interval: 100, raw: true) do
      5.times do
        GC.start
      end
    end

    gc_frame = profile[:frames].values.find{ |f| f[:name] == "(garbage collection)" }
    marking_frame = profile[:frames].values.find{ |f| f[:name] == "(marking)" }
    sweeping_frame = profile[:frames].values.find{ |f| f[:name] == "(sweeping)" }

    assert gc_frame
    assert marking_frame
    assert sweeping_frame

    assert_equal gc_frame[:total_samples], profile[:gc_samples]
    assert_equal profile[:gc_samples], [gc_frame, marking_frame, sweeping_frame].map{|x| x[:samples] }.inject(:+)

    assert_operator profile[:gc_samples], :>, 0
    assert_operator profile[:missed_samples], :<=, 25
  end

  def test_out
    tmpfile = Tempfile.new('stackprof-out')
    ret = StackProf.run(mode: :custom, out: tmpfile) do
      StackProf.sample
    end

    assert_equal tmpfile, ret
    tmpfile.rewind
    profile = Marshal.load(tmpfile.read)
    refute_empty profile[:frames]
  end

  def test_out_to_path_string
    tmpfile = Tempfile.new('stackprof-out')
    ret = StackProf.run(mode: :custom, out: tmpfile.path) do
      StackProf.sample
    end

    refute_equal tmpfile, ret
    assert_equal tmpfile.path, ret.path
    tmpfile.rewind
    profile = Marshal.load(tmpfile.read)
    refute_empty profile[:frames]
  end

  def test_pathname_out
    tmpfile  = Tempfile.new('stackprof-out')
    pathname = Pathname.new(tmpfile.path)
    ret = StackProf.run(mode: :custom, out: pathname) do
      StackProf.sample
    end

    assert_equal tmpfile.path, ret.path
    tmpfile.rewind
    profile = Marshal.load(tmpfile.read)
    refute_empty profile[:frames]
  end

  def test_min_max_interval
    [-1, 0, 1_000_000, 1_000_001].each do |invalid_interval|
      err = assert_raises(ArgumentError, "invalid interval #{invalid_interval}") do
        StackProf.run(interval: invalid_interval, debug: true) {}
      end
      assert_match(/microseconds/, err.message)
    end
  end

  def test_tag_thread_id
    profile = StackProf.run(mode: :cpu, tags: [:thread_id]) do
      100.times { math }
    end

    assert_equal true, profile.key?(:sample_tags)
    assert_equal profile[:samples], profile[:sample_tags].size
    assert_operator profile[:sample_tags].size, :>, 0
    assert_equal true, profile[:sample_tags].all? { |t| t.key?(:thread_id)}
    assert_equal true, profile[:sample_tags].all? { |t| Thread.current.to_s.include?(t[:thread_id])}
  end

  def test_tag_with_helper
    profile = StackProf.run(mode: :cpu, tags: [:foo]) do
      10.times { math }
      StackProf::Tag.with(foo: :bar) do
        10.times { math }
      end
      10.times { math }
    end
    #STDERR.puts "PROF #{profile[:sample_tags].inspect}"
    assert_equal true, profile.key?(:sample_tags)
    assert_equal profile[:samples], profile[:sample_tags].size
    assert_operator profile[:sample_tags].size, :>, 0
    assert_equal true, tag_order_matches(profile, [{}, {foo: :bar}, {}])
  end

  def test_tag_sample_from_tag_source_with_multiple_threads
    main_id = sub_id = ""
    profile = StackProf.run(mode: :cpu, tags: [:thread_id, :foo]) do
      main_id = parse_thread_id(Thread.current)
      StackProf::Tag.set(foo: :bar)
      Thread.new do
        sub_id = parse_thread_id(Thread.current)
        StackProf::Tag.set(foo: :baz)
        10.times { math }
      end.join
      10.times { math }
      StackProf::Tag.clear
      10.times { math }
    end

    assert_equal true, profile.key?(:sample_tags)
    assert_equal profile[:samples], profile[:sample_tags].size
    assert_operator profile[:sample_tags].size, :>, 0
    assert_equal true, profile[:sample_tags].all? { |t| t.key?(:thread_id) }

    assert_equal true, tag_order_matches(profile, [{thread_id: sub_id, foo: :baz}, {thread_id: main_id, foo: :bar}, {thread_id: main_id}])
  end


  def test_tag_samples_with_tags_as_closure
    main_id = sub_id = ""
    profile = StackProf.run(mode: :cpu, tags: [:foo, :spam]) do
      main_id = parse_thread_id(Thread.current)
      10.times { math }
      StackProf::Tag.with(foo: :bar) do
        10.times { math }
        StackProf::Tag.with(foo: :baz) do
          10.times { math }
          StackProf::Tag.with(spam: :eggs) do
            10.times { math }
          end
          10.times { math }
        end
        10.times { math }
      end
      10.times { math }
    end

    assert_equal true, profile.key?(:sample_tags)
    assert_equal profile[:samples], profile[:sample_tags].size
    assert_operator profile[:sample_tags].size, :>, 0
    #STDERR.puts "PROF #{profile[:sample_tags].inspect}"
    assert_equal true, tag_order_matches(profile, [{}, {foo: :bar}, {foo: :baz}, {foo: :baz, spam: :eggs}, {foo: :baz}, {foo: :bar}, {}])
  end

  #def test_tag_sample_from_tag_source_with_multiple_threads
  #  main_id = sub_id = ""
  #  profile = StackProf.run(mode: :cpu, tags: [:thread_id, :foo]) do
  #    main_id = parse_thread_id(Thread.current)
  #    StackProf::Tag.set(foo: :bar)
  #    Thread.new do
  #      sub_id = parse_thread_id(Thread.current)
  #      StackProf::Tag.set(foo: :baz)
  #      math
  #    end.join
  #    math
  #    StackProf::Tag.clear
  #    math
  #  end

  #  assert_equal true, profile.key?(:sample_tags)
  #  assert_equal profile[:samples], profile[:sample_tags].size
  #  assert_operator profile[:sample_tags].size, :>, 0
  #  assert_equal true, profile[:sample_tags].all? { |t| t.key?(:thread_id) }

  #  #STDERR.puts "PROF #{profile[:sample_tags].inspect}"
  #  assert_equal true, tag_order_matches(profile, [{thread_id: sub_id, foo: :baz}, {thread_id: main_id, foo: :bar}, {thread_id: main_id}])
  #end


  def test_tag_sample_from_custom_tag_source
    custom_tag_source = :my_custom_tag_source
    StackProf::Tag.set(foo: :bar, tag_source: custom_tag_source)
    profile = StackProf.run(mode: :cpu, tags: [:foo], tag_source: custom_tag_source) do
      10.times { math }
    end

    assert_equal true, profile.key?(:sample_tags)
    assert_equal profile[:samples], profile[:sample_tags].size
    assert_operator profile[:sample_tags].size, :>, 0
    assert_equal true, profile[:sample_tags].all? { |t| t[:foo] == :bar }
  end

  def test_tag_sample_with_symbol_or_string
    StackProf::Tag.set(foo: :bar, spam: "a lot")

    profile = StackProf.run(mode: :cpu, tags: [:foo, :spam]) do
      10.times { math }
    end

    assert_equal true, profile.key?(:sample_tags)
    assert_equal profile[:samples], profile[:sample_tags].size
    assert_operator profile[:sample_tags].size, :>, 0
    assert_equal true, profile[:sample_tags].all? { |t| t[:foo] == :bar }
    assert_equal true, profile[:sample_tags].all? { |t| t[:spam] == "a lot" }
  end

  def parse_thread_id(thread)
    thread.to_s.scan(/#<Thread:(.*?)\s.*>/).flatten.first
  end

  def tag_order_matches(profile, order)
    return false if order.size < 1
    idx = 0
    acceptable = nil
    profile.fetch(:sample_tags, []).each do |tags|
      acceptable = order[idx]
      if tags != acceptable && idx < order.size
        idx = idx + 1
        next_acceptable = order[idx]
        #STDERR.puts "HERE #{tags} != #{acceptable}, trying #{next_acceptable}"
        return false if tags != next_acceptable
        acceptable = next_acceptable
      end
    end
    return idx == (order.size - 1)
  end

  def math
    250_000.times do
      2 ** 10
    end
  end

  def idle
    r, w = IO.pipe
    IO.select([r], nil, nil, 0.2)
  ensure
    r.close
    w.close
  end
end unless RUBY_ENGINE == 'truffleruby'
