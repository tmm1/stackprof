require 'pp'

module StackProf
  class Report
    def initialize(data)
      @data = data
    end

    def frames
      @data[:frames].sort_by{ |iseq, stats| -stats[:samples] }
    end

    def overall_samples
      @data[:samples]
    end

    def print_debug
      pp @data
    end

    def print_graphviz(f = STDOUT)
      f.puts "digraph profile {"
      frames.each do |frame, info|
        call, total = info.values_at(:samples, :total_samples)
        sample = ''
        sample << "#{call} (%2.1f%%)\\rof " % (call*100.0/overall_samples) if call < total
        sample << "#{total} (%2.1f%%)\\r" % (total*100.0/overall_samples)
        size = (1.0 * call / overall_samples) * 28 + 10

        f.puts "  #{frame} [size=#{size}] [fontsize=#{size}] [shape=box] [label=\"#{info[:name]}\\n#{sample}\"];"
        if edges = info[:edges]
          edges.each do |edge, weight|
            size = (1.0 * weight / overall_samples) * 28
            f.puts "  #{frame} -> #{edge} [label=\"#{weight}\"];"
          end
        end
      end
      f.puts "}"
    end

    def print_text(f = STDOUT)
      f.printf "% 10s    (pct)  % 10s    (pct)     FRAME\n" % ["TOTAL", "SAMPLES"]
      frames.each do |frame, info|
        call, total = info.values_at(:samples, :total_samples)
        f.printf "% 10d % 8s  % 10d % 8s     %s\n", total, "(%2.1f%%)" % (total*100.0/overall_samples), call, "(%2.1f%%)" % (call*100.0/overall_samples), info[:name]
      end
    end

    def print_source(name, f = STDOUT)
      name = /#{Regexp.escape name}/ unless Regexp === name
      frames.each do |frame, info|
        next unless info[:name] =~ name
        file, line = info.values_at(:file, :line)

        maxline = info[:lines] ? info[:lines].keys.max : line + 5
        f.printf "%s (%s:%d)\n", info[:name], file, line

        lines = info[:lines]
        source = File.readlines(file).each_with_index do |code, i|
          next unless (line-1..maxline).include?(i)
          if lines and samples = lines[i+1]
            f.printf "% 5d % 7s / % 7s  | % 5d  | %s", samples, "(%2.1f%%" % (100.0*samples/overall_samples), "%2.1f%%)" % (100.0*samples/info[:samples]), i+1, code
          else
            f.printf "                         | % 5d  | %s", i+1, code
          end
        end
      end
    end
  end
end
