## stackprof

a sampling call-stack profiler for ruby 2.1+

inspired heavily by [gperftools](https://code.google.com/p/gperftools/),
and written as a replacement for [perftools.rb](https://github.com/tmm1/perftools.rb)

### sampling

three sampling modes are supported:

  - cpu time (using `ITIMER_PROF` and `SIGPROF`)
  - wall time (using `ITIMER_REAL` and `SIGALRM`)
  - object allocation (using `RUBY_INTERNAL_EVENT_NEWOBJ`)

samplers have a tuneable interval which can be used to reduce overhead or increase granularity:

  - cpu time: sample every <interval> microseconds of cpu activity (default: 10000 = 10 milliseconds)
  - wall time: sample every <interval> microseconds of wallclock time (default: 10000)
  - object allocation: sample every <interval> allocations (default: 1)

samples are taken using a combination of two new C-APIs in ruby 2.1:

  - signal handlers enqueue a sampling job using `rb_postponed_job_register_one`.
    this ensures callstack samples can be taken safely, in case the VM is garbage collecting
    or in some other inconsistent state during the interruption.

  - stack frames are collected via `rb_profile_frames`, which provides low-overhead C-API access
    to the VM's call stack. no object allocations occur in this path, allowing stackprof to collect
    callstacks even in allocation mode.

### aggregation

each sample consists of N stack frames, for example `MyClass#method` or `block in MySingleton.method`.
for each frame in a sample, the profiler collects some metadata:

  - samples: number of samples where this frame was the topmost (`samples+=1 if caller[0] == frame`)
  - lines: samples per line for this frame                      (`lines[frame.lineno]+=1 if caller[0] == frame`)
  - total: samples where this frame is in the stack             (`total+=1 if caller.include?(frame)`)
  - edges: samples per callee frame                             (`edges[frame.prev]+=1`)

this incrementally condenses samples down into a call graph. each frame in the graph points to other frames it calls.
the total for any frame equals the sum of its edges (`total == edges.values.sum`).
see the dot graph report example below for a visualization of these call graphs.

### reporting

four reporting modes are supported:
  - text
  - dotgraph
  - source annotation
  - raw

#### text

```
     TOTAL    (pct)     SAMPLES    (pct)     FRAME
        91  (48.4%)          91  (48.4%)     A#pow
        58  (30.9%)          58  (30.9%)     A.newobj
        34  (18.1%)          34  (18.1%)     block in A#math
       188 (100.0%)           3   (1.6%)     block (2 levels) in <main>
       185  (98.4%)           1   (0.5%)     A#initialize
        35  (18.6%)           1   (0.5%)     A#math
       188 (100.0%)           0   (0.0%)     <main>
       188 (100.0%)           0   (0.0%)     block in <main>
       188 (100.0%)           0   (0.0%)     <main>
```

#### dotgraph

![](http://cl.ly/image/2f351W161c1c/content)

```
digraph profile {
  70346498324780 [size=23.5531914893617] [fontsize=23.5531914893617] [shape=box] [label="A#pow\n91 (48.4%)\r"];
  70346498324680 [size=18.638297872340424] [fontsize=18.638297872340424] [shape=box] [label="A.newobj\n58 (30.9%)\r"];
  70346498324480 [size=15.063829787234042] [fontsize=15.063829787234042] [shape=box] [label="block in A#math\n34 (18.1%)\r"];
  70346498324220 [size=10.446808510638299] [fontsize=10.446808510638299] [shape=box] [label="block (2 levels) in <main>\n3 (1.6%)\rof 188 (100.0%)\r"];
  70346498324220 -> 70346498324900 [label="185"];
  70346498324900 [size=10.148936170212766] [fontsize=10.148936170212766] [shape=box] [label="A#initialize\n1 (0.5%)\rof 185 (98.4%)\r"];
  70346498324900 -> 70346498324780 [label="91"];
  70346498324900 -> 70346498324680 [label="58"];
  70346498324900 -> 70346498324580 [label="35"];
  70346498324580 [size=10.148936170212766] [fontsize=10.148936170212766] [shape=box] [label="A#math\n1 (0.5%)\rof 35 (18.6%)\r"];
  70346498324580 -> 70346498324480 [label="34"];
  70346497983360 [size=10.0] [fontsize=10.0] [shape=box] [label="<main>\n0 (0.0%)\rof 188 (100.0%)\r"];
  70346497983360 -> 70346498325080 [label="188"];
  70346498324300 [size=10.0] [fontsize=10.0] [shape=box] [label="block in <main>\n0 (0.0%)\rof 188 (100.0%)\r"];
  70346498324300 -> 70346498324220 [label="188"];
  70346498325080 [size=10.0] [fontsize=10.0] [shape=box] [label="<main>\n0 (0.0%)\rof 188 (100.0%)\r"];
  70346498325080 -> 70346498324300 [label="188"];
}
```

#### source annotation

```
A#pow (/Users/tmm1/code/stackprof/sample.rb:10)
                         |    11  |   def pow
   91  (48.4% / 100.0%)  |    12  |     2 ** 100
                         |    13  |   end
A.newobj (/Users/tmm1/code/stackprof/sample.rb:14)
                         |    15  |   def self.newobj
   33  (17.6% /  56.9%)  |    16  |     Object.new
   25  (13.3% /  43.1%)  |    17  |     Object.new
                         |    18  |   end
block in A#math (/Users/tmm1/code/stackprof/sample.rb:20)
                         |    21  |     2.times do
   34  (18.1% / 100.0%)  |    22  |       2 + 3 * 4 ^ 5 / 6
                         |    23  |     end
A#math (/Users/tmm1/code/stackprof/sample.rb:19)
                         |    20  |   def math
    1   (0.5% / 100.0%)  |    21  |     2.times do
                         |    22  |       2 + 3 * 4 ^ 5 / 6
```

#### raw

```
{:version=>1.0,
 :mode=>"cpu(1000)",
 :samples=>188,
 :frames=>
  {70346498324780=>
    {:name=>"A#pow",
     :file=>"/Users/tmm1/code/stackprof/sample.rb",
     :line=>11,
     :total_samples=>91,
     :samples=>91,
     :lines=>{12=>91}},
   70346498324900=>
    {:name=>"A#initialize",
     :file=>"/Users/tmm1/code/stackprof/sample.rb",
     :line=>5,
     :total_samples=>185,
     :samples=>1,
     :edges=>{70346498324780=>91, 70346498324680=>58, 70346498324580=>35},
     :lines=>{8=>1}},
   70346498324220=>
    {:name=>"block (2 levels) in <main>",
     :file=>"/Users/tmm1/code/stackprof/sample.rb",
     :line=>30,
     :total_samples=>188,
     :samples=>3,
     :edges=>{70346498324900=>185},
     :lines=>{31=>3}},
   70346498324300=>
    {:name=>"block in <main>",
     :file=>"/Users/tmm1/code/stackprof/sample.rb",
     :line=>29,
     :total_samples=>188,
     :samples=>0,
     :edges=>{70346498324220=>188}},
   70346498325080=>
    {:name=>"<main>",
     :file=>"/Users/tmm1/code/stackprof/sample.rb",
     :total_samples=>188,
     :samples=>0,
     :edges=>{70346498324300=>188}},
   70346497983360=>
    {:name=>"<main>",
     :file=>"sample.rb",
     :total_samples=>188,
     :samples=>0,
     :edges=>{70346498325080=>188}},
```
