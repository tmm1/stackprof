$:.unshift File.expand_path('../../lib', __FILE__)
require 'stackprof'
require 'minitest/autorun'

class ReportTest < MiniTest::Test
  require 'stringio'

  def test_dump_to_stdout
    data = {}
    report = StackProf::Report.new(data)

    out, _err = capture_subprocess_io do
      report.print_dump
    end

    assert_dump data, out
  end

  def test_dump_to_file
    data = {}
    f = StringIO.new
    report = StackProf::Report.new(data)

    report.print_dump(f)

    assert_dump data, f.string
  end

  def test_add
    p1 = StackProf.run(mode: :cpu, raw: true) do
      foo
    end
    p2 = StackProf.run(mode: :cpu, raw: true) do
      foo
      bar
    end

    combined = StackProf::Report.new(p1) + StackProf::Report.new(p2)

    assert_equal 2, find_method_frame(combined, :foo)[:total_samples]
    assert_equal 1, find_method_frame(combined, :bar)[:total_samples]
  end

  private

  def find_method_frame(profile, name)
    profile.frames.values.find do |frame|
      frame[:name] == "ReportTest##{name}"
    end
  end

  def foo
    StackProf.sample
  end

  def bar
    StackProf.sample
  end

  def assert_dump(expected, marshal_data)
    assert_equal expected, Marshal.load(marshal_data)
  end
end
