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

  def test_merge
    data = [
      StackProf.run(mode: :cpu, raw: true) do
        foo
      end,
      StackProf.run(mode: :cpu, raw: true) do
        foo
        bar
      end,
      StackProf.run(mode: :cpu, raw: true) do
        foo
        bar
        baz
      end
    ]
    expectations = {
      foo: {
        total_samples: 3,
        samples: 3,
        total_lines: 1,
      },
      bar: {
        total_samples: 4,
        samples: 2,
        total_lines: 2,
        has_boz_edge: true
      },
      baz: {
        total_samples: 2,
        samples: 1,
        total_lines: 2,
        has_boz_edge: true,
      },
      boz: {
        total_samples: 3,
        samples: 3,
        total_lines: 1,
      },
    }

    reports = data.map {|d| StackProf::Report.new(d)}
    combined = reports[0].merge(*reports[1..-1])

    frames = expectations.keys.inject(Hash.new) do |hash, key|
      hash[key] = find_method_frame(combined, key)
      hash
    end

    expectations.each do |key, expect|
      frame = frames[key]
      assert_equal expect[:total_samples], frame[:total_samples], key
      assert_equal expect[:samples], frame[:samples], key

      assert_equal expect[:total_lines], frame[:lines].length, key
      assert_includes frame[:lines], frame[:line] + 1, key
      assert_equal [expect[:samples], expect[:samples]], frame[:lines][frame[:line] + 1], key

      if expect[:has_boz_edge]
        assert_equal ({frames[:boz][:hash] => expect[:samples]}), frame[:edges]
      end
    end

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
    boz
  end

  def baz
    StackProf.sample
    boz
  end

  def boz
    StackProf.sample
  end

  def assert_dump(expected, marshal_data)
    assert_equal expected, Marshal.load(marshal_data)
  end
end

class ReportReadTest < MiniTest::Test
  require 'pathname'

  def test_from_file_read_json
    file = fixture("profile.json")
    report = StackProf::Report.from_file(file)

    assert_equal({ mode: "cpu" }, report.data)
  end

  def test_from_file_read_marshal
    file = fixture("profile.dump")
    report = StackProf::Report.from_file(file)

    assert_equal({ mode: "cpu" }, report.data)
  end

  private

  def fixture(name)
    Pathname.new(__dir__).join("fixtures", name)
  end
end
