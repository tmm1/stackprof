require 'mkmf'
if RUBY_ENGINE == 'truffleruby'
  fail "try truffleruby's profiler \nruby --experimental-options --cpusampler --cpusampler.Mode=roots --cpusampler.SampleInternal FILE.rb"
elsif have_func('rb_postponed_job_register_one') &&
   have_func('rb_profile_frames') &&
   have_func('rb_tracepoint_new') &&
   have_const('RUBY_INTERNAL_EVENT_NEWOBJ')
  create_makefile('stackprof/stackprof')
else
  fail 'missing API: are you using ruby 2.1+?'
end
