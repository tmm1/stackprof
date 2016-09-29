require 'pp'
require 'digest/md5'

module StackProf
  class Report
    def initialize(data)
      @data = data
    end
    attr_reader :data

    def frames(sort_by_total=false)
      @data[:"sorted_frames_#{sort_by_total}"] ||=
        @data[:frames].sort_by{ |iseq, stats| -stats[sort_by_total ? :total_samples : :samples] }.inject({}){|h, (k, v)| h[k] = v; h}
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

    def print_dump(f=STDOUT)
      f.puts Marshal.dump(@data.reject{|k,v| k == :files })
    end

    def print_stackcollapse
      raise "profile does not include raw samples (add `raw: true` to collecting StackProf.run)" unless raw = data[:raw]

      while len = raw.shift
        frames = raw.slice!(0, len)
        weight = raw.shift

        print frames.map{ |a| data[:frames][a][:name] }.join(';')
        puts " #{weight}"
      end
    end

    def print_flamegraph(f=STDOUT, skip_common=true)
      raise "profile does not include raw samples (add `raw: true` to collecting StackProf.run)" unless raw = data[:raw]

      stacks = []
      max_x = 0
      max_y = 0
      while len = raw.shift
        max_y = len if len > max_y
        stack = raw.slice!(0, len+1)
        stacks << stack
        max_x += stack.last
      end

      f.puts 'flamegraph(['
      max_y.times do |y|
        row_prev = nil
        row_width = 0
        x = 0

        stacks.each do |stack|
          weight = stack.last
          cell = stack[y] unless y == stack.length-1

          if cell.nil?
            if row_prev
              flamegraph_row(f, x - row_width, y, row_width, row_prev)
            end

            row_prev = nil
            x += weight
            next
          end

          if row_prev.nil?        # start new row with this cell
            row_width = weight
            row_prev = cell
            x += weight

          elsif row_prev == cell  # grow current row along x-axis
            row_width += weight
            x += weight

          else                    # end current row and start new row
            flamegraph_row(f, x - row_width, y, row_width, row_prev)
            x += weight
            row_prev = cell
            row_width = weight
          end

          row_prev = cell
        end

        if row_prev
          next if skip_common && row_width == max_x

          flamegraph_row(f, x - row_width, y, row_width, row_prev)
        end
      end
      f.puts '])'
    end

    def flamegraph_row(f, x, y, weight, addr)
      frame = frames[addr]
      f.print ',' if @rows_started
      @rows_started = true
      f.puts %{{"x":#{x},"y":#{y},"width":#{weight},"frame_id":#{addr},"frame":#{frame[:name].dump},"file":#{frame[:file].dump}}}
    end

    def print_graphviz(options = {}, f = STDOUT)
      if filter = options[:filter]
        mark_stack = []
        list = frames(true)
        list.each{ |addr, frame| mark_stack << addr if frame[:name] =~ filter }
        while addr = mark_stack.pop
          frame = list[addr]
          unless frame[:marked]
            mark_stack += frame[:edges].map{ |addr, weight| addr if list[addr][:total_samples] <= weight*1.2 }.compact if frame[:edges]
            frame[:marked] = true
          end
        end
        list = list.select{ |addr, frame| frame[:marked] }
        list.each{ |addr, frame| frame[:edges] && frame[:edges].delete_if{ |k,v| list[k].nil? } }
        list
      else
        list = frames(true)
      end


      limit = options[:limit]
      fraction = options[:node_fraction]

      included_nodes = {}
      node_minimum = fraction ? (fraction * overall_samples).ceil : 0

      f.puts "digraph profile {"
      f.puts "Legend [shape=box,fontsize=24,shape=plaintext,label=\""
      f.print "Total samples: #{overall_samples}\\l"
      f.print "Showing top #{limit} nodes\\l" if limit
      f.print "Dropped nodes with < #{node_minimum} samples\\l" if fraction
      f.puts "\"];"

      list.each_with_index do |(frame, info), index|
        call, total = info.values_at(:samples, :total_samples)
        break if total < node_minimum || (limit && index >= limit)

        sample = ''
        sample << "#{call} (%2.1f%%)\\rof " % (call*100.0/overall_samples) if call < total
        sample << "#{total} (%2.1f%%)\\r" % (total*100.0/overall_samples)
        fontsize = (1.0 * call / max_samples) * 28 + 10
        size = (1.0 * total / overall_samples) * 2.0 + 0.5

        f.puts "  \"#{frame}\" [size=#{size}] [fontsize=#{fontsize}] [penwidth=\"#{size}\"] [shape=box] [label=\"#{info[:name]}\\n#{sample}\"];"
        included_nodes[frame] = true
      end

      list.each do |frame, info|
        next unless included_nodes[frame]

        if edges = info[:edges]
          edges.each do |edge, weight|
            next unless included_nodes[edge]

            size = (1.0 * weight / overall_samples) * 2.0 + 0.5
            f.puts "  \"#{frame}\" -> \"#{edge}\" [label=\"#{weight}\"] [weight=\"#{weight}\"] [penwidth=\"#{size}\"];"
          end
        end
      end
      f.puts "}"
    end

    def print_text(sort_by_total=false, limit=nil, select_files= nil, reject_files=nil, select_names=nil, reject_names=nil, f = STDOUT)
      f.puts "=================================="
      f.printf "  Mode: #{modeline}\n"
      f.printf "  Samples: #{@data[:samples]} (%.2f%% miss rate)\n", 100.0*@data[:missed_samples]/(@data[:missed_samples]+@data[:samples])
      f.printf "  GC: #{@data[:gc_samples]} (%.2f%%)\n", 100.0*@data[:gc_samples]/@data[:samples]
      f.puts "=================================="
      f.printf "% 10s    (pct)  % 10s    (pct)     FRAME\n" % ["TOTAL", "SAMPLES"]
      list = frames(sort_by_total)
      list.select!{|_, info| select_files.any?{|path| info[:file].start_with?(path)}} if select_files
      list.select!{|_, info| select_names.any?{|reg| info[:name] =~ reg}} if select_names
      list.reject!{|_, info| reject_files.any?{|path| info[:file].start_with?(path)}} if reject_files
      list.reject!{|_, info| reject_names.any?{|reg| info[:name] =~ reg}} if reject_names
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
          f.puts "#{line} #{weight.is_a?(Array) ? weight[1] : weight}"
        end if frame[:lines]
        frame[:edges].each do |edge, weight|
          oframe = list[edge]
          f.puts "cfl=#{oframe[:file]}" unless oframe[:file] == frame[:file]
          f.puts "cfn=#{oframe[:name]}"
          f.puts "calls=#{weight} #{frame[:line] || 0}\n#{oframe[:line] || 0} #{weight}"
        end if frame[:edges]
        f.puts
      end

      f.puts "totals: #{@data[:samples]}"
    end

    def print_method(name, f = STDOUT)
      name = /#{name}/ unless Regexp === name
      frames.each do |frame, info|
        next unless info[:name] =~ name
        file, line = info.values_at(:file, :line)
        line ||= 1

        lines = info[:lines]
        maxline = lines ? lines.keys.max : line + 5
        f.printf "%s (%s:%d)\n", info[:name], file, line
        f.printf "  samples: % 5d self (%2.1f%%)  /  % 5d total (%2.1f%%)\n", info[:samples], 100.0*info[:samples]/overall_samples, info[:total_samples], 100.0*info[:total_samples]/overall_samples

        if (callers = callers_for(frame)).any?
          f.puts "  callers:"
          callers = callers.sort_by(&:last).reverse
          callers.each do |name, weight|
            f.printf "   % 5d  (% 8s)  %s\n", weight, "%3.1f%%" % (100.0*weight/info[:total_samples]), name
          end
        end

        if callees = info[:edges]
          f.printf "  callees (%d total):\n", info[:total_samples]-info[:samples]
          callees = callees.map{ |k, weight| [data[:frames][k][:name], weight] }.sort_by{ |k,v| -v }
          callees.each do |name, weight|
            f.printf "   % 5d  (% 8s)  %s\n", weight, "%3.1f%%" % (100.0*weight/(info[:total_samples]-info[:samples])), name
          end
        end

        f.puts "  code:"
        source_display(f, file, lines, line-1..maxline)
      end
    end

    def print_files(sort_by_total=false, limit=nil, f = STDOUT)
      list = files.map{ |file, vals| [file, vals.values.inject([0,0]){ |sum, n| add_lines(sum, n) }] }
      list = list.sort_by{ |file, samples| -samples[1] }
      list = list.first(limit) if limit
      list.each do |file, vals|
        total_samples, samples = *vals
        f.printf "% 5d  (%5.1f%%) / % 5d  (%5.1f%%)   %s\n", total_samples, (100.0*total_samples/overall_samples), samples, (100.0*samples/overall_samples), file
      end
    end

    def print_file(filter, f = STDOUT)
      filter = /#{Regexp.escape filter}/ unless Regexp === filter
      list = files.select{ |name, lines| name =~ filter }
      list.sort_by{ |file, vals| -vals.values.inject(0){ |sum, n| sum + (n.is_a?(Array) ? n[1] : n) } }.each do |file, lines|
        source_display(f, file, lines)
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
              lines[line] = add_lines(lines[line], weight)
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

    private
    def root_frames
      frames.select{ |addr, frame| callers_for(addr).size == 0  }
    end

    def callers_for(addr)
      @callers_for ||= {}
      @callers_for[addr] ||= data[:frames].map{ |id, other| [other[:name], other[:edges][addr]] if other[:edges] && other[:edges].include?(addr) }.compact
    end

    def source_display(f, file, lines, range=nil)
      File.readlines(file).each_with_index do |code, i|
        next unless range.nil? || range.include?(i)
        if lines and lineinfo = lines[i+1]
          total_samples, samples = lineinfo
          if version == 1.0
            samples = total_samples
            f.printf "% 5d % 7s  | % 5d  | %s", samples, "(%2.1f%%)" % (100.0*samples/overall_samples), i+1, code
          elsif samples > 0
            f.printf "% 5d  % 8s / % 5d  % 7s  | % 5d  | %s", total_samples, "(%2.1f%%)" % (100.0*total_samples/overall_samples), samples, "(%2.1f%%)" % (100.0*samples/overall_samples), i+1, code
          else
            f.printf "% 5d  % 8s                   | % 5d  | %s", total_samples, "(%3.1f%%)" % (100.0*total_samples/overall_samples), i+1, code
          end
        else
          if version == 1.0
            f.printf "               | % 5d  | %s", i+1, code
          else
            f.printf "                                  | % 5d  | %s", i+1, code
          end
        end
      end
    end

  end
end
