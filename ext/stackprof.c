/**********************************************************************

  stackprof.c - Sampling call-stack frame profiler for MRI.

  $Author$
  created at: Thu May 30 17:55:25 2013

  NOTE: This extension library is not expected to exist except C Ruby.

  All the files in this distribution are covered under the Ruby's
  license (see the file COPYING).

**********************************************************************/

#include <ruby/ruby.h>
#include <ruby/debug.h>
#include <ruby/st.h>
#include <sys/time.h>

#define BUF_SIZE 2048

typedef struct {
    size_t total_samples;
    size_t caller_samples;
    st_table *edges;
    st_table *lines;
} frame_data_t;

static struct {
    enum {
	PROF_NONE = 0,
	PROF_CPU,
	PROF_WALL,
	PROF_OBJECT
    } type;

    size_t overall_samples;
    st_table *frames;

    VALUE frames_buffer[BUF_SIZE];
    int lines_buffer[BUF_SIZE];
} _results;

static VALUE sym_object, sym_wall, sym_name, sym_file, sym_line;
static VALUE sym_samples, sym_total_samples, sym_edges, sym_lines;
static VALUE sym_version, sym_mode, sym_frames;
static VALUE objtracer;
static VALUE gc_hook;

static void stackprof_newobj_handler(VALUE, void*);
static void stackprof_signal_handler(int sig, siginfo_t* sinfo, void* ucontext);

static VALUE
stackprof_start(VALUE self, VALUE type, VALUE usec)
{
    if (type == sym_object) {
	_results.type = PROF_OBJECT;
	objtracer = rb_tracepoint_new(0, RUBY_INTERNAL_EVENT_NEWOBJ, stackprof_newobj_handler, 0);
	rb_tracepoint_enable(objtracer);
    } else {
	if (type == sym_wall)
	    _results.type = PROF_WALL;
	else
	    _results.type = PROF_CPU;

	struct sigaction sa;
	sa.sa_sigaction = stackprof_signal_handler;
	sa.sa_flags = SA_RESTART | SA_SIGINFO;
	sigemptyset(&sa.sa_mask);
	sigaction(_results.type == PROF_WALL ? SIGALRM : SIGPROF, &sa, NULL);

	struct itimerval timer;
	timer.it_interval.tv_sec = 0;
	timer.it_interval.tv_usec = NUM2LONG(usec);
	timer.it_value = timer.it_interval;
	setitimer(_results.type == PROF_WALL ? ITIMER_REAL : ITIMER_PROF, &timer, 0);
    }

    return Qnil;
}

static VALUE
stackprof_stop(VALUE self)
{
    if (_results.type == PROF_OBJECT) {
	rb_tracepoint_disable(objtracer);
    } else {
	struct itimerval timer;
	memset(&timer, 0, sizeof(timer));
	setitimer(_results.type == PROF_WALL ? ITIMER_REAL : ITIMER_PROF, &timer, 0);

	struct sigaction sa;
	sa.sa_handler = SIG_IGN;
	sa.sa_flags = SA_RESTART;
	sigemptyset(&sa.sa_mask);
	sigaction(_results.type == PROF_WALL ? SIGALRM : SIGPROF, &sa, NULL);
    }

    return Qnil;
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

    intptr_t weight = (intptr_t)val;
    rb_hash_aset(lines, INT2FIX(key), INT2FIX(weight));
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
    VALUE label, method_name;
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
stackprof_run(VALUE self, VALUE type, VALUE usec)
{
    VALUE results, frames;
    rb_need_block();
    if (!_results.frames)
	_results.frames = st_init_numtable();
    _results.overall_samples = 0;

    stackprof_start(self, type, usec);
    rb_yield(Qundef);
    stackprof_stop(self);

    results = rb_hash_new();
    rb_hash_aset(results, sym_version, DBL2NUM(1.0));
    rb_hash_aset(results, sym_mode, rb_sprintf("%"PRIsVALUE"(%"PRIsVALUE")", type, usec));
    rb_hash_aset(results, sym_samples, SIZET2NUM(_results.overall_samples));

    frames = rb_hash_new();
    rb_hash_aset(results, sym_frames, frames);
    st_foreach(_results.frames, frame_i, (st_data_t)frames);

    return results;
}

static inline frame_data_t *
sample_for(VALUE frame)
{
    st_data_t key = (st_data_t)frame, val = 0;
    frame_data_t *frame_data;

    if (st_lookup(_results.frames, key, &val)) {
        frame_data = (frame_data_t *)val;
    } else {
        frame_data = ALLOC_N(frame_data_t, 1);
        MEMZERO(frame_data, frame_data_t, 1);
        val = (st_data_t)frame_data;
        st_insert(_results.frames, key, val);
    }

    return frame_data;
}

void
st_numtable_increment(st_table *table, st_data_t key)
{
    intptr_t weight = 0;
    st_lookup(table, key, (st_data_t *)&weight);
    weight++;
    st_insert(table, key, weight);
}

static void
stackprof_sample()
{
    int num, i;
    VALUE prev_frame;
    st_data_t key;

    _results.overall_samples++;
    num = rb_profile_frames(0, sizeof(_results.frames_buffer), _results.frames_buffer, _results.lines_buffer);

    for (i = 0; i < num; i++) {
	int line = _results.lines_buffer[i];
	VALUE frame = _results.frames_buffer[i];
	frame_data_t *frame_data = sample_for(frame);

	frame_data->total_samples++;

	if (i == 0) {
	    frame_data->caller_samples++;
	    if (line > 0) {
		if (!frame_data->lines)
		    frame_data->lines = st_init_numtable();
		st_numtable_increment(frame_data->lines, (st_data_t)line);
	    }
	} else {
	    if (!frame_data->edges)
		frame_data->edges = st_init_numtable();
	    st_numtable_increment(frame_data->edges, (st_data_t)prev_frame);
	}

	prev_frame = frame;
    }
}

static void
stackprof_job_handler(void *data)
{
    static int in_signal_handler = 0;
    if (in_signal_handler) return;

    in_signal_handler++;
    stackprof_sample();
    in_signal_handler--;
}

static void
stackprof_signal_handler(int sig, siginfo_t *sinfo, void *ucontext)
{
    rb_postponed_job_register_one(0, stackprof_job_handler, 0);
}

static void
stackprof_newobj_handler(VALUE tpval, void *data)
{
    stackprof_job_handler(0);
}

static int
frame_mark_i(st_data_t key, st_data_t val, st_data_t arg)
{
    VALUE frame = (VALUE)key;
    rb_gc_mark_maybe(frame);
    return ST_CONTINUE;
}

static void
stackprof_gc_mark()
{
    if (_results.frames)
	st_foreach(_results.frames, frame_mark_i, 0);
}

void
Init_stackprof(void)
{
    sym_object = ID2SYM(rb_intern("object"));
    sym_name = ID2SYM(rb_intern("name"));
    sym_wall = ID2SYM(rb_intern("wall"));
    sym_file = ID2SYM(rb_intern("file"));
    sym_line = ID2SYM(rb_intern("line"));
    sym_total_samples = ID2SYM(rb_intern("total_samples"));
    sym_samples = ID2SYM(rb_intern("samples"));
    sym_edges = ID2SYM(rb_intern("edges"));
    sym_lines = ID2SYM(rb_intern("lines"));
    sym_version = ID2SYM(rb_intern("version"));
    sym_mode = ID2SYM(rb_intern("mode"));
    sym_frames = ID2SYM(rb_intern("frames"));

    gc_hook = Data_Wrap_Struct(rb_cObject, stackprof_gc_mark, NULL, NULL);
    rb_global_variable(&gc_hook);

    VALUE rb_mStackProf = rb_define_module("StackProf");
    rb_define_singleton_method(rb_mStackProf, "run", stackprof_run, 2);
    rb_autoload(rb_mStackProf, rb_intern_const("Report"), "stackprof/report.rb");
}
