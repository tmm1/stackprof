$:.unshift File.expand_path('../../lib', __FILE__)
require 'stackprof'
require 'minitest/autorun'
require 'tempfile'

class StackProfTest < MiniTest::Test
  def test_info
    profile = StackProf.run{}
    assert_equal 1.2, profile[:version]
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
    assert_equal 2, profile[:samples]

    frame = profile[:frames].values.first
    assert_includes frame[:name], "StackProfTest#test_object_allocation"
    assert_equal 2, frame[:samples]
    assert_includes [profile_base_line - 2, profile_base_line], frame[:line]
    assert_equal [1, 1], frame[:lines][profile_base_line+1]
    assert_equal [1, 1], frame[:lines][profile_base_line+2]
    frame = profile[:frames].values[1] if RUBY_VERSION < '2.3'
    assert_equal [2, 0], frame[:lines][profile_base_line]
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
    frame = profile[:frames].values.first
    assert_includes frame[:name], "StackProfTest#math"
  end

  def test_walltime
    profile = StackProf.run(mode: :wall) do
      idle
    end

    frame = profile[:frames].values.first
    assert_equal "StackProfTest#idle", frame[:name]
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

    frame = profile[:frames].values.first
    assert_includes frame[:name], "StackProfTest#test_custom"
    assert_includes [profile_base_line-2, profile_base_line+1], frame[:line]
    assert_equal [10, 10], frame[:lines][profile_base_line+2]
  end

  def test_raw
    profile = StackProf.run(mode: :custom, raw: true) do
      10.times do
        StackProf.sample
      end
    end

    raw = profile[:raw]
    assert_equal 10, raw[-1]
    assert_equal raw[0] + 2, raw.size
    assert_includes profile[:frames][raw[-2]][:name], 'StackProfTest#test_raw'
    assert_equal 10, profile[:raw_timestamp_deltas].size
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

    raw = profile[:raw]
    gc_frame = profile[:frames].values.find{ |f| f[:name] == "(garbage collection)" }
    assert gc_frame
    assert_equal gc_frame[:samples], profile[:gc_samples]
    assert_operator profile[:gc_samples], :>, 0
    assert_operator profile[:missed_samples], :<=, 10
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
end
