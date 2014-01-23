/**********************************************************************

  stackprof.c - Sampling call-stack frame profiler for MRI.

  vim: setl noexpandtab shiftwidth=4 tabstop=8 softtabstop=4

**********************************************************************/

#include <ruby/ruby.h>
#include <ruby/debug.h>
#include <ruby/st.h>
#include <signal.h>
#include <sys/time.h>
#include <pthread.h>

#define BUF_SIZE 2048

typedef struct {
    size_t total_samples;
    size_t caller_samples;
    st_table *edges;
    st_table *lines;
} frame_data_t;

static struct {
    int running;
    VALUE mode;
    VALUE interval;

    size_t overall_signals;
    size_t overall_samples;
    size_t during_gc;
    st_table *frames;

    VALUE frames_buffer[BUF_SIZE];
    int lines_buffer[BUF_SIZE];
} _stackprof;

static VALUE sym_object, sym_wall, sym_cpu, sym_custom, sym_name, sym_file, sym_line;
static VALUE sym_samples, sym_total_samples, sym_missed_samples, sym_edges, sym_lines;
static VALUE sym_version, sym_mode, sym_interval, sym_frames;
static VALUE sym_gc_samples, objtracer;
static VALUE gc_hook;
static VALUE rb_mStackProf;

static void stackprof_newobj_handler(VALUE, void*);
static void stackprof_signal_handler(int sig, siginfo_t* sinfo, void* ucontext);

static VALUE
stackprof_start(int argc, VALUE *argv, VALUE self)
{
    struct sigaction sa;
    struct itimerval timer;
    VALUE opts = Qnil, mode = Qnil, interval = Qnil;

    if (_stackprof.running)
	return Qfalse;

    rb_scan_args(argc, argv, "0:", &opts);

    if (RTEST(opts)) {
	mode = rb_hash_aref(opts, sym_mode);
	interval = rb_hash_aref(opts, sym_interval);
    }
    if (!RTEST(mode)) mode = sym_wall;

    if (!_stackprof.frames) {
	_stackprof.frames = st_init_numtable();
	_stackprof.overall_signals = 0;
	_stackprof.overall_samples = 0;
	_stackprof.during_gc = 0;
    }

    if (mode == sym_object) {
	if (!RTEST(interval)) interval = INT2FIX(1);

	objtracer = rb_tracepoint_new(0, RUBY_INTERNAL_EVENT_NEWOBJ, stackprof_newobj_handler, 0);
	rb_tracepoint_enable(objtracer);
    } else if (mode == sym_wall || mode == sym_cpu) {
	if (!RTEST(interval)) interval = INT2FIX(1000);

	sa.sa_sigaction = stackprof_signal_handler;
	sa.sa_flags = SA_RESTART | SA_SIGINFO;
	sigemptyset(&sa.sa_mask);
	sigaction(mode == sym_wall ? SIGALRM : SIGPROF, &sa, NULL);

	timer.it_interval.tv_sec = 0;
	timer.it_interval.tv_usec = NUM2LONG(interval);
	timer.it_value = timer.it_interval;
	setitimer(mode == sym_wall ? ITIMER_REAL : ITIMER_PROF, &timer, 0);
    } else if (mode == sym_custom) {
	/* sampled manually */
	interval = Qnil;
    } else {
	rb_raise(rb_eArgError, "unknown profiler mode");
    }

    _stackprof.running = 1;
    _stackprof.mode = mode;
    _stackprof.interval = interval;

    return Qtrue;
}

static VALUE
stackprof_stop(VALUE self)
{
    struct sigaction sa;
    struct itimerval timer;

    if (!_stackprof.running)
	return Qfalse;
    _stackprof.running = 0;

    if (_stackprof.mode == sym_object) {
	rb_tracepoint_disable(objtracer);
    } else if (_stackprof.mode == sym_wall || _stackprof.mode == sym_cpu) {
	memset(&timer, 0, sizeof(timer));
	setitimer(_stackprof.mode == sym_wall ? ITIMER_REAL : ITIMER_PROF, &timer, 0);

	sa.sa_handler = SIG_IGN;
	sa.sa_flags = SA_RESTART;
	sigemptyset(&sa.sa_mask);
	sigaction(_stackprof.mode == sym_wall ? SIGALRM : SIGPROF, &sa, NULL);
    } else if (_stackprof.mode == sym_custom) {
	/* sampled manually */
    } else {
	rb_raise(rb_eArgError, "unknown profiler mode");
    }

    return Qtrue;
}

static int
frame_edges_i(st_data_t key, st_data_t val, st_data_t arg)
{
    VALUE edges = (VALUE)arg;

    intptr_t weight = (intptr_t)val;
    rb_hash_aset(edges, rb_obj_id((VALUE)key), INT2FIX(weight));
    return ST_CONTINUE;
}

static int
frame_lines_i(st_data_t key, st_data_t val, st_data_t arg)
{
    VALUE lines = (VALUE)arg;

    size_t weight = (size_t)val;
    size_t total = weight & (~(size_t)0 << (8*SIZEOF_SIZE_T/2));
    weight -= total;
    total = total >> (8*SIZEOF_SIZE_T/2);
    rb_hash_aset(lines, INT2FIX(key), rb_ary_new3(2, ULONG2NUM(total), ULONG2NUM(weight)));
    return ST_CONTINUE;
}

static int
frame_i(st_data_t key, st_data_t val, st_data_t arg)
{
    VALUE frame = (VALUE)key;
    frame_data_t *frame_data = (frame_data_t *)val;
    VALUE results = (VALUE)arg;
    VALUE details = rb_hash_new();
    VALUE name, file, edges, lines;
    VALUE line;

    rb_hash_aset(results, rb_obj_id(frame), details);

    name = rb_profile_frame_full_label(frame);
    rb_hash_aset(details, sym_name, name);

    file = rb_profile_frame_absolute_path(frame);
    if (NIL_P(file))
	file = rb_profile_frame_path(frame);
    rb_hash_aset(details, sym_file, file);

    if ((line = rb_profile_frame_first_lineno(frame)) != INT2FIX(0))
	rb_hash_aset(details, sym_line, line);

    rb_hash_aset(details, sym_total_samples, SIZET2NUM(frame_data->total_samples));
    rb_hash_aset(details, sym_samples, SIZET2NUM(frame_data->caller_samples));

    if (frame_data->edges) {
        edges = rb_hash_new();
        rb_hash_aset(details, sym_edges, edges);
        st_foreach(frame_data->edges, frame_edges_i, (st_data_t)edges);
        st_free_table(frame_data->edges);
        frame_data->edges = NULL;
    }

    if (frame_data->lines) {
	lines = rb_hash_new();
	rb_hash_aset(details, sym_lines, lines);
	st_foreach(frame_data->lines, frame_lines_i, (st_data_t)lines);
	st_free_table(frame_data->lines);
	frame_data->lines = NULL;
    }

    xfree(frame_data);
    return ST_DELETE;
}

static VALUE
stackprof_results(VALUE self)
{
    VALUE results, frames;

    if (!_stackprof.frames || _stackprof.running)
	return Qnil;

    results = rb_hash_new();
    rb_hash_aset(results, sym_version, DBL2NUM(1.1));
    rb_hash_aset(results, sym_mode, _stackprof.mode);
    rb_hash_aset(results, sym_interval, _stackprof.interval);
    rb_hash_aset(results, sym_samples, SIZET2NUM(_stackprof.overall_samples));
    rb_hash_aset(results, sym_gc_samples, SIZET2NUM(_stackprof.during_gc));
    rb_hash_aset(results, sym_missed_samples, SIZET2NUM(_stackprof.overall_signals - _stackprof.overall_samples));

    frames = rb_hash_new();
    rb_hash_aset(results, sym_frames, frames);
    st_foreach(_stackprof.frames, frame_i, (st_data_t)frames);

    st_free_table(_stackprof.frames);
    _stackprof.frames = NULL;

    return results;
}

static VALUE
stackprof_run(int argc, VALUE *argv, VALUE self)
{
    rb_need_block();
    stackprof_start(argc, argv, self);
    rb_ensure(rb_yield, Qundef, stackprof_stop, self);
    return stackprof_results(self);
}

static VALUE
stackprof_running_p(VALUE self)
{
    return _stackprof.running ? Qtrue : Qfalse;
}

static inline frame_data_t *
sample_for(VALUE frame)
{
    st_data_t key = (st_data_t)frame, val = 0;
    frame_data_t *frame_data;

    if (st_lookup(_stackprof.frames, key, &val)) {
        frame_data = (frame_data_t *)val;
    } else {
        frame_data = ALLOC_N(frame_data_t, 1);
        MEMZERO(frame_data, frame_data_t, 1);
        val = (st_data_t)frame_data;
        st_insert(_stackprof.frames, key, val);
    }

    return frame_data;
}

static int
numtable_increment_callback(st_data_t *key, st_data_t *value, st_data_t arg, int existing)
{
    size_t *weight = (size_t *)value;
    size_t increment = (size_t)arg;

    if (existing)
	(*weight) += increment;
    else
	*weight = increment;

    return ST_CONTINUE;
}

void
st_numtable_increment(st_table *table, st_data_t key, size_t increment)
{
    st_update(table, key, numtable_increment_callback, (st_data_t)increment);
}

void
stackprof_record_sample()
{
    int num, i;
    VALUE prev_frame = Qnil;

    _stackprof.overall_samples++;
    num = rb_profile_frames(0, sizeof(_stackprof.frames_buffer), _stackprof.frames_buffer, _stackprof.lines_buffer);

    for (i = 0; i < num; i++) {
	int line = _stackprof.lines_buffer[i];
	VALUE frame = _stackprof.frames_buffer[i];
	frame_data_t *frame_data = sample_for(frame);

	frame_data->total_samples++;

	if (i == 0) {
	    frame_data->caller_samples++;
	} else {
	    if (!frame_data->edges)
		frame_data->edges = st_init_numtable();
	    st_numtable_increment(frame_data->edges, (st_data_t)prev_frame, 1);
	}

	if (line > 0) {
	    if (!frame_data->lines)
		frame_data->lines = st_init_numtable();
	    size_t half = (size_t)1<<(8*SIZEOF_SIZE_T/2);
	    size_t increment = i == 0 ? half + 1 : half;
	    st_numtable_increment(frame_data->lines, (st_data_t)line, increment);
	}

	prev_frame = frame;
    }
}

static void
stackprof_job_handler(void *data)
{
    static int in_signal_handler = 0;
    if (in_signal_handler) return;
    if (!_stackprof.running) return;

    in_signal_handler++;
    stackprof_record_sample();
    in_signal_handler--;
}

static void
stackprof_signal_handler(int sig, siginfo_t *sinfo, void *ucontext)
{
    _stackprof.overall_signals++;
    if (rb_during_gc())
	_stackprof.during_gc++, _stackprof.overall_samples++;
    else
	rb_postponed_job_register_one(0, stackprof_job_handler, 0);
}

static void
stackprof_newobj_handler(VALUE tpval, void *data)
{
    _stackprof.overall_signals++;
    stackprof_job_handler(0);
}

static VALUE
stackprof_sample(VALUE self)
{
    if (!_stackprof.running)
	return Qfalse;

    _stackprof.overall_signals++;
    stackprof_job_handler(0);
    return Qtrue;
}

static int
frame_mark_i(st_data_t key, st_data_t val, st_data_t arg)
{
    VALUE frame = (VALUE)key;
    rb_gc_mark(frame);
    return ST_CONTINUE;
}

static void
stackprof_gc_mark(void *data)
{
    if (_stackprof.frames)
	st_foreach(_stackprof.frames, frame_mark_i, 0);
}

static void
stackprof_atfork_prepare(void)
{
    struct itimerval timer;
    if (_stackprof.running) {
	if (_stackprof.mode == sym_wall || _stackprof.mode == sym_cpu) {
	    memset(&timer, 0, sizeof(timer));
	    setitimer(_stackprof.mode == sym_wall ? ITIMER_REAL : ITIMER_PROF, &timer, 0);
	}
    }
}

static void
stackprof_atfork_parent(void)
{
    struct itimerval timer;
    if (_stackprof.running) {
	if (_stackprof.mode == sym_wall || _stackprof.mode == sym_cpu) {
	    timer.it_interval.tv_sec = 0;
	    timer.it_interval.tv_usec = NUM2LONG(_stackprof.interval);
	    timer.it_value = timer.it_interval;
	    setitimer(_stackprof.mode == sym_wall ? ITIMER_REAL : ITIMER_PROF, &timer, 0);
	}
    }
}

static void
stackprof_atfork_child(void)
{
    stackprof_stop(rb_mStackProf);
}

void
Init_stackprof(void)
{
    sym_object = ID2SYM(rb_intern("object"));
    sym_custom = ID2SYM(rb_intern("custom"));
    sym_wall = ID2SYM(rb_intern("wall"));
    sym_cpu = ID2SYM(rb_intern("cpu"));
    sym_name = ID2SYM(rb_intern("name"));
    sym_file = ID2SYM(rb_intern("file"));
    sym_line = ID2SYM(rb_intern("line"));
    sym_total_samples = ID2SYM(rb_intern("total_samples"));
    sym_gc_samples = ID2SYM(rb_intern("gc_samples"));
    sym_missed_samples = ID2SYM(rb_intern("missed_samples"));
    sym_samples = ID2SYM(rb_intern("samples"));
    sym_edges = ID2SYM(rb_intern("edges"));
    sym_lines = ID2SYM(rb_intern("lines"));
    sym_version = ID2SYM(rb_intern("version"));
    sym_mode = ID2SYM(rb_intern("mode"));
    sym_interval = ID2SYM(rb_intern("interval"));
    sym_frames = ID2SYM(rb_intern("frames"));

    gc_hook = Data_Wrap_Struct(rb_cObject, stackprof_gc_mark, NULL, NULL);
    rb_global_variable(&gc_hook);

    rb_mStackProf = rb_define_module("StackProf");
    rb_define_singleton_method(rb_mStackProf, "running?", stackprof_running_p, 0);
    rb_define_singleton_method(rb_mStackProf, "run", stackprof_run, -1);
    rb_define_singleton_method(rb_mStackProf, "start", stackprof_start, -1);
    rb_define_singleton_method(rb_mStackProf, "stop", stackprof_stop, 0);
    rb_define_singleton_method(rb_mStackProf, "results", stackprof_results, 0);
    rb_define_singleton_method(rb_mStackProf, "sample", stackprof_sample, 0);

    rb_autoload(rb_mStackProf, rb_intern_const("Report"), "stackprof/report.rb");
    rb_autoload(rb_mStackProf, rb_intern_const("Middleware"), "stackprof/middleware.rb");

    pthread_atfork(stackprof_atfork_prepare, stackprof_atfork_parent, stackprof_atfork_child);
}
