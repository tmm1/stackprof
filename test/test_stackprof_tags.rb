# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'stackprof'
require 'minitest/autorun'

class StackProfTagsTest < MiniTest::Test
  def teardown
    StackProf::Tag.clear
    StackProf::Tag::Persistence.disable
  end

  def test_tag_fields_present_if_tags
    profile = StackProf.run(tags: [:thread_id]) do
      assert_operator StackProf::Tag.check, :==, {}
      math
    end

    assert_equal true, profile.key?(:sample_tags)
    assert_equal true, profile.key?(:tag_strings)
    assert_equal true, profile.key?(:num_tags)
  end

  def test_tag_fields_not_present_if_no_tags
    profile = StackProf.run do
      assert_operator StackProf::Tag.check, :==, {}
      math
    end

    assert_equal false, profile.key?(:sample_tags)
    assert_equal false, profile.key?(:tag_strings)
    assert_equal false, profile.key?(:num_tags)
  end

  def test_one_tagset_per_profile
    profile = StackProf.run(tags: [:thread_id]) do
      assert_operator StackProf::Tag.check, :==, {}
      math
    end

    assert_equal profile[:samples], profile[:num_tags]
    assert_equal true, profile.key?(:sample_tags)
    assert_equal profile[:num_tags], profile[:sample_tags].select { |e| e.is_a?(Integer) }.inject(0, :+)
  end

  def test_tag_thread_id
    profile = StackProf.run(mode: :wall, tags: [:thread_id], raw: true) do # FIXME: try :wall to make tests faster
      assert_operator StackProf::Tag.check, :==, {}
      math(10)
    end

    assert_equal true, profile.key?(:sample_tags)
    assert_operator profile[:sample_tags].size, :>, 0
    assert_equal profile[:samples], StackProf::Tags.from(profile).size
    assert_equal true, all_samples_have_tag(profile, :thread_id)
    assert_equal true, StackProf::Tags.from(profile).all? { |t| Thread.current.to_s.include?(t[:thread_id]) }
  end

  def test_tag_with_helper
    profile = StackProf.run(mode: :cpu, tags: [:foo], raw: true) do
      math(10)
      StackProf::Tag.with(foo: :bar) do
        assert_operator StackProf::Tag.check, :==, { foo: :bar }
        math(10)
      end
      math(10)
    end

    assert_equal true, profile.key?(:sample_tags)
    assert_operator profile[:sample_tags].size, :>, 0
    assert_equal profile[:samples], StackProf::Tags.from(profile).size
    assert_equal true, tag_order_matches(profile, [{}, { foo: 'bar' }, {}])
  end

  def test_tag_sample_from_custom_tag_source
    custom_tag_source = :my_custom_tag_source
    StackProf::Tag.set(foo: :bar, tag_source: custom_tag_source)
    profile = StackProf.run(mode: :cpu, tags: [:foo], tag_source: custom_tag_source, raw: true) do
      assert_operator StackProf::Tag.check(tag_source: custom_tag_source), :==, { foo: :bar }
      math(10)
    end

    assert_equal true, profile.key?(:sample_tags)
    assert_operator profile[:sample_tags].size, :>, 0
    assert_equal profile[:samples], StackProf::Tags.from(profile).size
    assert_equal true, all_samples_have_tag(profile, :foo)
    assert_equal true, StackProf::Tags.from(profile).all? { |t| t[:foo] == 'bar' }
  end

  def test_tag_sample_with_symbol_or_string
    StackProf::Tag.set(foo: :bar, spam: 'a lot')

    profile = StackProf.run(mode: :cpu, tags: %i[foo spam], raw: true) do
      assert_operator StackProf::Tag.check, :==, { foo: :bar, spam: 'a lot' }
      math(10)
    end

    assert_equal true, profile.key?(:sample_tags)
    assert_operator profile[:sample_tags].size, :>, 0
    assert_equal profile[:samples], StackProf::Tags.from(profile).size
    assert_equal true, all_samples_have_tag(profile, :foo)
    assert_equal true, StackProf::Tags.from(profile).all? { |t| t[:foo] == 'bar' }
    assert_equal true, all_samples_have_tag(profile, :spam)
    assert_equal true, StackProf::Tags.from(profile).all? { |t| t[:spam] == 'a lot' }
  end

  def test_tag_samples_with_tags_as_closure
    profile = StackProf.run(mode: :cpu, tags: %i[foo spam], raw: true) do
      math(10)
      StackProf::Tag.with(foo: :bar) do
        assert_operator StackProf::Tag.check, :==, { foo: :bar }
        math(10)
        StackProf::Tag.with(foo: :baz) do
          assert_operator StackProf::Tag.check, :==, { foo: :baz }
          math(10)
          StackProf::Tag.with(spam: :eggs) do
            assert_operator StackProf::Tag.check, :==, { foo: :baz, spam: :eggs }
            math(10)
          end
          math(10)
        end
        math(10)
      end
      math(10)
    end

    assert_equal true, profile.key?(:sample_tags)
    assert_operator profile[:sample_tags].size, :>, 0
    assert_equal profile[:samples], StackProf::Tags.from(profile).size
    assert_equal true,
                 tag_order_matches(profile,
                                   [{},
                                    { foo: 'bar' },
                                    { foo: 'baz' },
                                    { foo: 'baz', spam: 'eggs' },
                                    { foo: 'baz' },
                                    { foo: 'bar' },
                                    {}])
  end

  def test_tag_sample_in_thread
    thread_id = ''
    profile = StackProf.run(mode: :cpu, tags: %i[thread_id foo spam], raw: true) do
      Thread.new do
        thread_id = parse_thread_id(Thread.current)
        assert_operator StackProf::Tag.check, :==, {}
        math(10)
        StackProf::Tag.set(foo: :bar)
        assert_operator StackProf::Tag.check, :==, { foo: :bar }
        math(10)
        StackProf::Tag.set(foo: :bar, spam: 'eggs')
        assert_operator StackProf::Tag.check, :==, { foo: :bar, spam: 'eggs' }
        math(10)
      end.join
    end

    assert_equal true, profile.key?(:sample_tags)
    assert_operator profile[:sample_tags].size, :>, 0
    assert_equal profile[:samples], StackProf::Tags.from(profile).size
    assert_equal true, all_samples_have_tag(profile, :thread_id)
    assert_equal true,
                 tag_order_matches(profile,
                                   [{ thread_id: thread_id },
                                    { thread_id: thread_id, foo: 'bar' },
                                    { thread_id: thread_id, foo: 'bar', spam: 'eggs' }])
  end

  def test_truncate_tags_exceeding_length
    max_tags = StackProf::Tag::MAX_TAGS
    max_key_len = StackProf::Tag::MAX_TAG_KEY_LEN
    max_val_len = StackProf::Tag::MAX_TAG_VAL_LEN

    too_long_key = ('a' * (max_key_len + 1)).to_sym
    truncated_key = ('a' * max_key_len).to_sym
    StackProf::Tag.set(too_long_key => :bar)
    assert_operator StackProf::Tag.check, :==, { too_long_key => :bar }
    profile = StackProf.run(mode: :cpu, tags: [too_long_key]) do
      math(10)
    end
    StackProf::Tag.clear
    assert_operator StackProf::Tag.check, :==, {}

    assert_equal true, profile.key?(:sample_tags)
    assert_operator profile[:sample_tags].size, :>, 0
    assert_equal profile[:samples], StackProf::Tags.from(profile).size
    assert_equal true, all_samples_have_tag(profile, truncated_key)
    assert_equal true,
                 tag_order_matches(profile,
                                   [{ truncated_key => 'bar' }])

    too_long_val = ('a' * (max_val_len + 1))
    truncated_val = ('a' * max_val_len)
    StackProf::Tag.set(foo: too_long_val)
    assert_operator StackProf::Tag.check, :==, { foo: too_long_val }
    profile = StackProf.run(mode: :cpu, tags: %i[foo]) do
      math(10)
    end
    StackProf::Tag.clear
    assert_operator StackProf::Tag.check, :==, {}

    assert_equal true, profile.key?(:sample_tags)
    assert_operator profile[:sample_tags].size, :>, 0
    assert_equal profile[:samples], StackProf::Tags.from(profile).size
    assert_equal true, all_samples_have_tag(profile, :foo)
    assert_equal true,
                 tag_order_matches(profile,
                                   [{ foo: truncated_val }])

    too_many_tags = (max_tags + 1).times.map { :tag }
    error = assert_raises(ArgumentError) do
      StackProf.run(mode: :cpu, tags: too_many_tags) {}
    end
    assert_equal 'exceeding maximum number of tags', error.message
  end

  def test_no_tags_set
    assert_operator StackProf::Tag.check, :==, {}
    profile = StackProf.run(mode: :wall, tags: %i[foo]) do
      assert_operator StackProf::Tag.check, :==, {}
      math
    end
    assert_operator StackProf::Tag.check, :==, {}
    assert_equal true, profile.key?(:sample_tags)
    assert_equal profile[:samples], profile[:num_tags]
    assert_equal profile[:samples], StackProf::Tags.from(profile).size
    assert_equal true, StackProf::Tags.from(profile).all? { |t| t.empty? }
  end

  def test_tag_sample_from_tag_source_with_multiple_threads
    main_id = parse_thread_id(Thread.current)
    sub_id = ''
    StackProf::Tag.set(foo: :bar)

    profile = StackProf.run(mode: :cpu, tags: %i[thread_id foo], raw: true) do
      assert_operator StackProf::Tag.check, :==, { foo: :bar }
      math(10)
      Thread.new do
        sub_id = parse_thread_id(Thread.current)
        math(10)
        StackProf::Tag.set(foo: :baz)
        assert_operator StackProf::Tag.check, :==, { foo: :baz }
        math(10)
      end.join
      assert_operator StackProf::Tag.check, :==, { foo: :bar }
      math(10)
      StackProf::Tag.clear
      assert_operator StackProf::Tag.check, :==, {}
      math(10)
    end

    assert_equal true, profile.key?(:sample_tags)
    assert_operator profile[:sample_tags].size, :>, 0
    assert_equal profile[:samples], StackProf::Tags.from(profile).size
    assert_equal true, all_samples_have_tag(profile, :thread_id)
    assert_equal true,
                 tag_order_matches(profile,
                                   [{ thread_id: main_id, foo: 'bar' },
                                    { thread_id: sub_id },
                                    { thread_id: sub_id, foo: 'baz' },
                                    { thread_id: main_id, foo: 'bar' },
                                    { thread_id: main_id }])
  end

  def test_tagged_funtions_do_not_skew
    def fast_function
      StackProf::Tag.with(function: :fast) do
        math(2)
      end
    end

    def slow_function
      StackProf::Tag.with(function: :slow) do
        math(8)
      end
    end

    profile = StackProf.run(mode: :cpu, tags: %i[thread_id function], raw: true) do
      5.times do
        math(5)
        fast_function
        math(5)
        slow_function
      end
      math(5)
    end

    assert_equal true, profile.key?(:sample_tags)
    assert_operator profile[:sample_tags].size, :>, 0
    assert_equal profile[:samples], StackProf::Tags.from(profile).size
    assert_equal true, all_samples_have_tag(profile, :thread_id)

    main_tid = parse_thread_id(Thread.current)
    expected_order = [{ thread_id: main_tid },
                      { thread_id: main_tid, function: 'fast' },
                      { thread_id: main_tid },
                      { thread_id: main_tid, function: 'slow' }] * 5
    expected_order << { thread_id: main_tid }

    assert_equal true, tag_order_matches(profile, expected_order)

    samples = parse_profile(profile)

    sample_tags = StackProf::Tags.from(profile)
    i = 0
    while i < profile[:samples]
      tags = sample_tags[i]
      i += 1
      function = tags[:function]
      next unless function

      # Ensure that none of the samples are mis-tagged
      if function == :fast
        assert_equal true, samples[i].any? { |f| f.include?('fast_function') }
        assert_equal true, samples[i].all? { |f| !f.include?('slow_function') }
      elsif function == :slow
        assert_equal true, samples[i].any? { |f| f.include?('slow_function') }
        assert_equal true, samples[i].all? { |f| !f.include?('fast_function') }
      end
    end
  end

  def test_sample_tag_persistence_from_parent
    StackProf::Tag::Persistence.enable
    assert_equal true, StackProf::Tag::Persistence.enabled

    main_id = parse_thread_id(Thread.current)
    sub_id = ''

    StackProf::Tag.set(foo: :bar, spam: :eggs)
    assert_operator StackProf::Tag.check, :==, { foo: :bar, spam: :eggs }

    profile = StackProf.run(mode: :cpu, tags: %i[thread_id foo spam], raw: true) do
      math(10)
      Thread.new do
        sub_id = parse_thread_id(Thread.current)
        assert_operator StackProf::Tag.check, :==, { foo: :bar, spam: :eggs }
        math(10)
        StackProf::Tag.set(foo: :baz)
        assert_operator StackProf::Tag.check, :==, { foo: :baz, spam: :eggs }
        math(10)
      end.join
      math(10)
      StackProf::Tag.clear
      assert_operator StackProf::Tag.check, :==, {}
      math(10)
    end

    assert_equal true, profile.key?(:sample_tags)
    assert_operator profile[:sample_tags].size, :>, 0
    assert_equal profile[:samples], StackProf::Tags.from(profile).size
    assert_equal true, all_samples_have_tag(profile, :thread_id)

    allowed_orders = [
      [{ thread_id: main_id, foo: "bar", spam: "eggs" },
       { thread_id: sub_id, foo: "bar", spam: "eggs" },
       { thread_id: sub_id, foo: "baz", spam: "eggs" },
       { thread_id: main_id, foo: "bar", spam: "eggs" },
       { thread_id: main_id }],
      [{ thread_id: main_id, foo: "bar", spam: "eggs" },
       { thread_id: sub_id }, # Covers race condition where a sample is taken before tags set in child
       { thread_id: sub_id, foo: "bar", spam: "eggs" },
       { thread_id: sub_id, foo: "baz", spam: "eggs" },
       { thread_id: main_id, foo: "bar", spam: "eggs" },
       { thread_id: main_id }]
    ]

    assert_equal true, tag_order_matches(profile, *allowed_orders)

    # Now let's disable it and verify things are back to normal
    StackProf::Tag.set(foo: :bar, spam: :eggs)
    assert_operator StackProf::Tag.check, :==, { foo: :bar, spam: :eggs }

    StackProf::Tag::Persistence.disable
    assert_equal false, StackProf::Tag::Persistence.enabled

    profile = StackProf.run(mode: :cpu, tags: %i[thread_id foo spam], raw: true) do
      math(10)
      Thread.new do
        sub_id = parse_thread_id(Thread.current)
        assert_operator StackProf::Tag.check, :==, { }
        math(10)
        StackProf::Tag.set(foo: :baz)
        assert_operator StackProf::Tag.check, :==, { foo: :baz }
        math(10)
      end.join
      math(10)
      StackProf::Tag.clear
      assert_operator StackProf::Tag.check, :==, {}
      math(10)
    end

    assert_equal true, profile.key?(:sample_tags)
    assert_operator profile[:sample_tags].size, :>, 0
    assert_equal profile[:samples], StackProf::Tags.from(profile).size
    assert_equal true, all_samples_have_tag(profile, :thread_id)

    assert_equal true,
                 tag_order_matches(profile,
                                   [{ thread_id: main_id, foo: "bar", spam: "eggs" },
                                    { thread_id: sub_id },
                                    { thread_id: sub_id, foo: "baz" },
                                    { thread_id: main_id, foo: "bar", spam: "eggs" },
                                    { thread_id: main_id }])
  end

  private

  def math(n = 1)
    base = 250_000
    (n * base).times do
      2**10
    end
  end

  def parse_thread_id(thread)
    thread.to_s.scan(/#<Thread:(\w*)/).flatten.first
  end

  def all_samples_have_tag(profile, tag)
    tags = StackProf::Tags.from(profile)
    rc = tags.all? { |t| t.key?(tag) }
  ensure
    unless rc
      missing = tags.count { |t| !t.key?(tag) }
      puts "#{missing}/#{tags.size} samples did not contain the tag #{tag}"
      puts "GC samples: #{profile[:gc_samples]}"
      puts "Tags were: #{StackProf::Tags.from(profile).inspect}\nraw: #{profile[:sample_tags].inspect}\nstrtab: #{profile[:tag_strings].inspect}"
      if profile[:raw] && missing <= 5 # arbitrary limit to prevent spamming output
        samplemap = parse_profile(profile)
        tags.each_with_index do |t, i|
          puts "Sample missing tag #{tag}:\n#{samplemap[i].inspect}" unless t.key?(tag)
        end
      end
    end
  end

  def tag_order_matches(profile, *permitted_orders)
    debugstr = ''
    rc = false
    sampleIdx = 0
    next_acceptable = nil

    return rc if permitted_orders.empty?

    sampleTags = StackProf::Tags.from(profile)

    permitted_orders.each_with_index do |order, orderIdx|
      idx = 0
      acceptable = nil
      sampleTags.each do |tags|
        sampleIdx += 1
        acceptable = order[idx]
        next unless tags != acceptable && idx < order.size

        idx += 1
        next_acceptable = order[idx]
        debugstr += format("%02d/%02d: %s != %s, next %s (order %d)\n", idx, order.size, tags, acceptable,
                           next_acceptable, orderIdx)
        break if tags != next_acceptable

        acceptable = next_acceptable
      end
      rc = idx == (order.size - 1)
      return rc if rc
    end
    rc
  ensure
    unless rc
      puts "Failed on sample #{sampleIdx - 1}/#{sampleTags.size} -> #{sampleTags[sampleIdx - 1]} != #{next_acceptable}"
      puts "GC samples: #{profile[:gc_samples]}"
      puts "Tags were: #{StackProf::Tags.from(profile).inspect}\nraw: #{profile[:sample_tags].inspect}\nstrtab: #{profile[:tag_strings]}\n#{debugstr}"
    end
  end

  # Parses the stackprof hash into a map of samples id to callchains
  def parse_profile(profile)
    return unless profile.key?(:raw)

    stacks = {}
    raw = profile[:raw]
    i = 0
    stack_id = 0
    samples = 0
    puts "NO DATA for sample #{i}" if raw.size == 0
    while i < raw.size
      stack_height = raw[i]
      stack_id += 1
      i += 1
      j = 0

      stack = []
      while j < stack_height
        j += 1
        id = raw[i]
        i += 1
        frame = profile[:frames][id][:name]
        stack.push frame
      end

      num_samples = raw[i]
      j = 0
      while j < num_samples
        j += 1
        samples += 1
        # printf("sample %02d: { stack %02d, num_samples=%02d, depth=%02d }\n", samples, stack_id, num_samples, stack_height)
        stacks[samples] = stack
      end
      i += 1
    end
    stacks
  end
end unless RUBY_ENGINE == 'truffleruby'
