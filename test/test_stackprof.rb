$:.unshift File.expand_path('../../lib', __FILE__)
require 'stackprof'
require 'test/unit'

class StackProfTest < Test::Unit::TestCase
  def test_info
    profile = StackProf.run(:wall, 1000){}
    assert_equal 1.0, profile[:version]
    assert_equal "wall(1000)", profile[:mode]
    assert_equal 0, profile[:samples]
  end

  def test_object_allocation
    profile = StackProf.run(:object, 1) do
      Object.new
      Object.new
    end
    assert_equal "object(1)", profile[:mode]
    assert_equal 2, profile[:samples]

    frame = profile[:frames].values.first
    assert_equal "block in StackProfTest#test_object_allocation", frame[:name]
    assert_equal 2, frame[:samples]
    assert_equal 14, frame[:line]
    assert_equal 1, frame[:lines][15]
    assert_equal 1, frame[:lines][16]
  end

  def test_cputime
    profile = StackProf.run(:cpu, 1000) do
      math
    end

    frame = profile[:frames].values.first
    assert_equal "block in StackProfTest#math", frame[:name]
  end

  def test_walltime
    profile = StackProf.run(:wall, 1000) do
      idle
    end

    frame = profile[:frames].values.first
    assert_equal "StackProfTest#idle", frame[:name]
    assert_in_delta 200, frame[:samples], 5
  end

  def math
    250_000.times do
      2 ** 10
    end
  end

  def idle
    sleep 0.2
  end
end
