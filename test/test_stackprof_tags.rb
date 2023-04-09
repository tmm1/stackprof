# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'stackprof'
require 'minitest/autorun'

class StackProfTagsTest < MiniTest::Test
  def teardown
    StackProf::Tag.clear
    StackProf::Tag::Persistence.disable
  end

  def test_tag_thread_id
    profile = StackProf.run(mode: :cpu, tags: [:thread_id]) do # FIXME: try :wall to make tests faster
      math(100) # FIXME: way too big
    end

    assert_equal true, profile.key?(:sample_tags)
    assert_equal profile[:samples], profile[:sample_tags].size
    assert_operator profile[:sample_tags].size, :>, 0
    assert_equal true, profile[:sample_tags].all? { |t| t.key?(:thread_id) }
    assert_equal true, profile[:sample_tags].all? { |t| Thread.current.to_s.include?(t[:thread_id]) }
  end

  def test_tag_with_helper
    profile = StackProf.run(mode: :cpu, tags: [:foo]) do
      math(10)
      StackProf::Tag.with(foo: :bar) do
        math(10)
      end
      math(10)
    end
    # STDERR.puts "PROF #{profile[:sample_tags].inspect}"
    assert_equal true, profile.key?(:sample_tags)
    assert_equal profile[:samples], profile[:sample_tags].size
    assert_operator profile[:sample_tags].size, :>, 0
    assert_equal true, tag_order_matches(profile, [{}, { foo: :bar }, {}])
  end


  def test_tag_sample_from_custom_tag_source
    custom_tag_source = :my_custom_tag_source
    StackProf::Tag.set(foo: :bar, tag_source: custom_tag_source)
    profile = StackProf.run(mode: :cpu, tags: [:foo], tag_source: custom_tag_source) do
      math(10)
    end

    assert_equal true, profile.key?(:sample_tags)
    assert_equal profile[:samples], profile[:sample_tags].size
    assert_operator profile[:sample_tags].size, :>, 0
    assert_equal true, profile[:sample_tags].all? { |t| t[:foo] == :bar }
  end

  def test_tag_sample_with_symbol_or_string
    StackProf::Tag.set(foo: :bar, spam: 'a lot')

    profile = StackProf.run(mode: :cpu, tags: %i[foo spam]) do
      math(10)
    end

    assert_equal true, profile.key?(:sample_tags)
    assert_equal profile[:samples], profile[:sample_tags].size
    assert_operator profile[:sample_tags].size, :>, 0
    assert_equal true, profile[:sample_tags].all? { |t| t[:foo] == :bar }
    assert_equal true, profile[:sample_tags].all? { |t| t[:spam] == 'a lot' }
  end

  def test_tag_samples_with_tags_as_closure
    main_id = sub_id = ''
    profile = StackProf.run(mode: :cpu, tags: %i[foo spam]) do
      main_id = parse_thread_id(Thread.current)
      math(10)
      StackProf::Tag.with(foo: :bar) do
        math(10)
        StackProf::Tag.with(foo: :baz) do
          math(10)
          StackProf::Tag.with(spam: :eggs) do
            math(10)
          end
          math(10)
        end
        math(10)
      end
      math(10)
    end

    assert_equal true, profile.key?(:sample_tags)
    assert_equal profile[:samples], profile[:sample_tags].size
    assert_operator profile[:sample_tags].size, :>, 0
    # STDERR.puts "PROF #{profile[:sample_tags].inspect}"
    assert_equal true,
                 tag_order_matches(profile,
                                   [{},
                                    { foo: :bar },
                                    { foo: :baz },
                                    { foo: :baz, spam: :eggs },
                                    { foo: :baz },
                                    { foo: :bar },
                                    {}])
  end

  def test_tag_sample_from_tag_source_with_multiple_threads
    main_id = sub_id = ''
    profile = StackProf.run(mode: :cpu, tags: %i[thread_id foo]) do
      main_id = parse_thread_id(Thread.current)
      StackProf::Tag.set(foo: :bar)
      Thread.new do
        sub_id = parse_thread_id(Thread.current)
        StackProf::Tag.set(foo: :baz)
        math(10)
      end.join
      math(10)
      StackProf::Tag.clear
      math(10)
    end

    assert_equal true, profile.key?(:sample_tags)
    assert_equal profile[:samples], profile[:sample_tags].size
    assert_operator profile[:sample_tags].size, :>, 0
    assert_equal true, profile[:sample_tags].all? { |t| t.key?(:thread_id) }

    assert_equal true,
                 tag_order_matches(profile,
                                   [{ thread_id: sub_id, foo: :baz },
                                    { thread_id: main_id, foo: :bar },
                                    { thread_id: main_id }])
  end

  def test_sample_tag_persistence_from_parent
    StackProf::Tag::Persistence.enable
    assert_equal true, StackProf::Tag::Persistence.enabled

    main_id = parse_thread_id(Thread.current)
    sub_id = ''

    StackProf::Tag.set(foo: :bar, spam: :eggs)
    assert_operator StackProf::Tag.check, :==, { foo: :bar, spam: :eggs }

    profile = StackProf.run(mode: :cpu, tags: %i[thread_id foo spam]) do
      Thread.new do
        StackProf::Tag.set(foo: :baz)
        assert_operator StackProf::Tag.check, :==, { foo: :baz, spam: :eggs }
        sub_id = parse_thread_id(Thread.current)
        math(1)
      end.join
      math(1)
      StackProf::Tag.clear
      assert_operator StackProf::Tag.check, :==, {}
      math(1)
    end

    assert_equal true, profile.key?(:sample_tags)
    assert_equal profile[:samples], profile[:sample_tags].size
    assert_operator profile[:sample_tags].size, :>, 0
    assert_equal true, profile[:sample_tags].all? { |t| t.key?(:thread_id) }

    # STDERR.puts "PROF #{profile[:sample_tags].inspect}"
    assert_equal true,
                 tag_order_matches(profile,
                                   [{ thread_id: sub_id, foo: :baz, spam: :eggs },
                                    { thread_id: main_id, foo: :bar, spam: :eggs },
                                    { thread_id: main_id }])

    # Now let's disable it and verify things are back to normal
    StackProf::Tag.set(foo: :bar, spam: :eggs)
    assert_operator StackProf::Tag.check, :==, { foo: :bar, spam: :eggs }

    StackProf::Tag::Persistence.disable
    assert_equal false, StackProf::Tag::Persistence.enabled

    profile = StackProf.run(mode: :cpu, tags: %i[thread_id foo spam]) do
      Thread.new do
        StackProf::Tag.set(foo: :baz)
        assert_operator StackProf::Tag.check, :==, { foo: :baz }
        sub_id = parse_thread_id(Thread.current)
        math(10)
      end.join
      math(10)
      StackProf::Tag.clear
      assert_operator StackProf::Tag.check, :==, {}
      math(10)
    end

    assert_equal true, profile.key?(:sample_tags)
    assert_equal profile[:samples], profile[:sample_tags].size
    assert_operator profile[:sample_tags].size, :>, 0
    assert_equal true, profile[:sample_tags].all? { |t| t.key?(:thread_id) }

    # STDERR.puts "PROF #{profile[:sample_tags].inspect}"
    assert_equal true,
                 tag_order_matches(profile,
                                   [{ thread_id: sub_id, foo: :baz },
                                    { thread_id: main_id, foo: :bar, spam: :eggs },
                                    { thread_id: main_id }])
  end

  def parse_thread_id(thread)
    thread.to_s.scan(/#<Thread:(.*?)\s.*>/).flatten.first
  end

  # TODO: build up a debug string to print and call from ensure clause
  def tag_order_matches(profile, order)
    debugstr = ''
    rc = false
    return rc if order.empty?

    idx = 0
    acceptable = nil
    profile.fetch(:sample_tags, []).each do |tags|
      acceptable = order[idx]
      next unless tags != acceptable && idx < order.size

      idx += 1
      next_acceptable = order[idx]
      debugstr += format("%02d/%02d) %s != %s, next %s\n", idx, order.size, tags, acceptable, next_acceptable)
      break if tags != next_acceptable

      acceptable = next_acceptable
    end
    rc = idx == (order.size - 1)
  ensure
    puts debugstr unless rc
  end

  def math(n)
    base = 250_000
    (n * base).times do
      2**10
    end
  end
end
