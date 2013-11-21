require 'pp'
require 'digest/md5'

module StackProf
  class Report
    def initialize(data)
      @data = data

      frames = {}
      @data[:frames].each{ |k,v| frames[k.to_s] = v }
      @data[:frames] = frames
    end
    attr_reader :data

    def frames(sort_by_total=false)
      Hash[ *@data[:frames].sort_by{ |iseq, stats| -stats[sort_by_total ? :total_samples : :samples] }.flatten(1) ]
    end

    def normalized_frames
      id2hash = {}
      @data[:frames].each do |frame, info|
        id2hash[frame.to_s] = info[:hash] = Digest::MD5.hexdigest("#{info[:name]}#{info[:file]}#{info[:line]}")
      end
      @data[:frames].inject(Hash.new) do |hash, (frame, info)|
        info = hash[id2hash[frame.to_s]] = info.dup
        info[:edges] = info[:edges].inject(Hash.new){ |edges, (edge, weight)| edges[id2hash[edge.to_s]] = weight; edges } if info[:edges]
        hash
      end
    end

    def version
      @data[:version]
    end

    def modeline
      "#{@data[:mode]}(#{@data[:interval]})"
    end

    def overall_samples
      @data[:samples]
    end

    def max_samples
      @data[:max_samples] ||= frames.max_by{ |addr, frame| frame[:samples] }.last[:samples]
    end

    def files
      @data[:files] ||= @data[:frames].inject(Hash.new) do |hash, (addr, frame)|
        if file = frame[:file] and lines = frame[:lines]
          hash[file] ||= Hash.new
          lines.each do |line, weight|
            hash[file][line] = add_lines(hash[file][line], weight)
          end
        end
        hash
      end
    end

    def add_lines(a, b)
      return b if a.nil?
      return a+b if a.is_a? Fixnum
      return [ a[0], a[1]+b ] if b.is_a? Fixnum
      [ a[0]+b[0], a[1]+b[1] ]
    end

    def print_debug
      pp @data
    end

    def print_graphviz(filter = nil, f = STDOUT)
      if filter
        mark_stack = []
        list = frames
        list.each{ |addr, frame| mark_stack << addr if frame[:name] =~ filter }
        while addr = mark_stack.pop
          frame = list[addr]
          unless frame[:marked]
            $stderr.puts frame[:edges].inspect
            mark_stack += frame[:edges].map{ |addr, weight| addr.to_s if list[addr.to_s][:total_samples] <= weight*1.2 }.compact if frame[:edges]
            frame[:marked] = true
          end
        end
        list = list.select{ |addr, frame| frame[:marked] }
        list.each{ |addr, frame| frame[:edges] && frame[:edges].delete_if{ |k,v| list[k.to_s].nil? } }
        list
      else
        list = frames
      end

      f.puts "digraph profile {"
      list.each do |frame, info|
        call, total = info.values_at(:samples, :total_samples)
        sample = ''
        sample << "#{call} (%2.1f%%)\\rof " % (call*100.0/overall_samples) if call < total
        sample << "#{total} (%2.1f%%)\\r" % (total*100.0/overall_samples)
        fontsize = (1.0 * call / max_samples) * 28 + 10
        size = (1.0 * total / overall_samples) * 2.0 + 0.5

        f.puts "  #{frame} [size=#{size}] [fontsize=#{fontsize}] [penwidth=\"#{size}\"] [shape=box] [label=\"#{info[:name]}\\n#{sample}\"];"
        if edges = info[:edges]
          edges.each do |edge, weight|
            size = (1.0 * weight / overall_samples) * 2.0 + 0.5
            f.puts "  #{frame} -> #{edge} [label=\"#{weight}\"] [weight=\"#{weight}\"] [penwidth=\"#{size}\"];"
          end
        end
      end
      f.puts "}"
    end

    def print_text(sort_by_total=false, limit=nil, f = STDOUT)
      f.puts "=================================="
      f.printf "  Mode: #{modeline}\n"
      f.printf "  Samples: #{@data[:samples]} (%.2f%% miss rate)\n", 100.0*@data[:missed_samples]/(@data[:missed_samples]+@data[:samples])
      f.printf "  GC: #{@data[:gc_samples]} (%.2f%%)\n", 100.0*@data[:gc_samples]/@data[:samples]
      f.puts "=================================="
      f.printf "% 10s    (pct)  % 10s    (pct)     FRAME\n" % ["TOTAL", "SAMPLES"]
      list = frames(sort_by_total)
      list = list.first(limit) if limit
      list.each do |frame, info|
        call, total = info.values_at(:samples, :total_samples)
        f.printf "% 10d % 8s  % 10d % 8s     %s\n", total, "(%2.1f%%)" % (total*100.0/overall_samples), call, "(%2.1f%%)" % (call*100.0/overall_samples), info[:name]
      end
    end

    def print_callgrind(f = STDOUT)
      f.puts "version: 1"
      f.puts "creator: stackprof"
      f.puts "pid: 0"
      f.puts "cmd: ruby"
      f.puts "part: 1"
      f.puts "desc: mode: #{modeline}"
      f.puts "desc: missed: #{@data[:missed_samples]})"
      f.puts "positions: line"
      f.puts "events: Instructions"
      f.puts "summary: #{@data[:samples]}"

      list = frames
      list.each do |addr, frame|
        f.puts "fl=#{frame[:file]}"
        f.puts "fn=#{frame[:name]}"
        frame[:lines].each do |line, weight|
          f.puts "#{line} #{weight}"
        end if frame[:lines]
        frame[:edges].each do |edge, weight|
          oframe = list[edge.to_s]
          f.puts "cfl=#{oframe[:file]}" unless oframe[:file] == frame[:file]
          f.puts "cfn=#{oframe[:name]}"
          f.puts "calls=#{weight} #{frame[:line] || 0}\n#{oframe[:line] || 0} #{weight}"
        end if frame[:edges]
        f.puts
      end

      f.puts "totals: #{@data[:samples]}"
    end

    def print_method(name, f = STDOUT)
      name = /#{Regexp.escape name}/ unless Regexp === name
      frames.each do |frame, info|
        next unless info[:name] =~ name
        file, line = info.values_at(:file, :line)
        line ||= 1

        maxline = info[:lines] ? info[:lines].keys.max : line + 5
        f.printf "%s (%s:%d)\n", info[:name], file, line

        lines = info[:lines]
        source_display(f, file, lines, line-1..maxline)
      end
    end

    def print_files(sort_by_total=false, limit=nil, f = STDOUT)
      list = files.map{ |file, vals| [file, vals.values.inject([0,0]){ |sum, n| add_lines(sum, n) }] }
      list = list.sort_by{ |file, samples| -samples[1] }
      list = list.first(limit) if limit
      list.each do |file, vals|
        total_samples, samples = *vals
        f.printf "% 5d  (%2.1f%%) / % 5d  (%2.1f%%) %s\n", total_samples, (100.0*total_samples/overall_samples), samples, (100.0*samples/overall_samples), file
      end
    end

    def print_file(filter, f = STDOUT)
      filter = /#{Regexp.escape filter}/ unless Regexp === filter
      list = files
      list.select!{ |name, lines| name =~ filter }
      list.sort_by{ |file, vals| -vals.values.inject(&:+) }.each do |file, lines|
        source_display(f, file, lines)
      end
    end

    private

    def source_display(f, file, lines, range=nil)
      File.readlines(file).each_with_index do |code, i|
        next unless range.nil? || range.include?(i)
        if lines and samples = lines[i+1] and samples > 0
          f.printf "% 5d % 7s  | % 5d  | %s", samples, "(%2.1f%%)" % (100.0*samples/overall_samples), i+1, code
        else
          f.printf "               | % 5d  | %s", i+1, code
        end
      end
    end

    def +(other)
      raise ArgumentError, "cannot combine #{other.class}" unless self.class == other.class
      raise ArgumentError, "cannot combine #{modeline} with #{other.modeline}" unless modeline == other.modeline
      raise ArgumentError, "cannot combine v#{version} with v#{other.version}" unless version == other.version

      f1, f2 = normalized_frames, other.normalized_frames
      frames = (f1.keys + f2.keys).uniq.inject(Hash.new) do |hash, id|
        if f1[id].nil?
          hash[id] = f2[id]
        elsif f2[id]
          hash[id] = f1[id]
          hash[id][:total_samples] += f2[id][:total_samples]
          hash[id][:samples] += f2[id][:samples]
          if f2[id][:edges]
            edges = hash[id][:edges] ||= {}
            f2[id][:edges].each do |edge, weight|
              edges[edge] ||= 0
              edges[edge] += weight
            end
          end
          if f2[id][:lines]
            lines = hash[id][:lines] ||= {}
            f2[id][:lines].each do |line, weight|
              lines[line] ||= 0
              lines[line] += weight
            end
          end
        else
          hash[id] = f1[id]
        end
        hash
      end

      d1, d2 = data, other.data
      data = {
        version: version,
        mode: d1[:mode],
        interval: d1[:interval],
        samples: d1[:samples] + d2[:samples],
        gc_samples: d1[:gc_samples] + d2[:gc_samples],
        missed_samples: d1[:missed_samples] + d2[:missed_samples],
        frames: frames
      }

      self.class.new(data)
    end
  end
end
