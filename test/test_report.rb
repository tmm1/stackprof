$:.unshift File.expand_path('../../lib', __FILE__)
require 'stackprof'
require 'minitest/autorun'

class ReportDumpTest < MiniTest::Test
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

  private

  def assert_dump(expected, marshal_data)
    assert_equal expected, Marshal.load(marshal_data)
  end
end
