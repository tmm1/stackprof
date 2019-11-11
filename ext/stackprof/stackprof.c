/**********************************************************************

  stackprof.c - Sampling call-stack frame profiler for MRI.

  vim: noexpandtab shiftwidth=4 tabstop=8 softtabstop=4

**********************************************************************/

#include <ruby/ruby.h>
#include <ruby/debug.h>
#include <ruby/st.h>
#include <ruby/io.h>
#include <ruby/intern.h>
#include <signal.h>
#include <sys/time.h>
#include <pthread.h>
#include <stdint.h>

#define BUF_SIZE 2048
#define MICROSECONDS_IN_SECOND 1000000

typedef struct {
    size_t total_samples;
    size_t caller_samples;
    size_t seen_at_sample_number;
    st_table *edges;
    st_table *lines;
} frame_data_t;

static struct {
    int running;
    int raw;
    int aggregate;
    int in_signal_handler;

    VALUE mode;
    VALUE interval;
    VALUE out;
    VALUE debug;

    VALUE *raw_samples;
    size_t raw_samples_len;
    size_t raw_samples_capa;
    size_t raw_sample_index;

    struct timeval started_at;
    struct timeval last_sample_at;
    int64_t *raw_timestamp_deltas;
    size_t raw_timestamp_deltas_len;
    size_t raw_timestamp_deltas_capa;

    size_t overall_signals;
    size_t overall_samples;
    size_t during_gc;
    size_t unrecorded_gc_samples;
    st_table *frames;

    VALUE fake_gc_frame;
    VALUE fake_gc_frame_name;
    VALUE empty_string;
    VALUE frames_buffer[BUF_SIZE];
    int lines_buffer[BUF_SIZE];
} _stackprof;

static VALUE sym_object, sym_wall, sym_cpu, sym_custom, sym_name, sym_file, sym_line;
static VALUE sym_samples, sym_total_samples, sym_missed_samples, sym_edges, sym_lines;
static VALUE sym_version, sym_mode, sym_interval, sym_raw, sym_frames, sym_out, sym_aggregate, sym_raw_timestamp_deltas;
static VALUE sym_debug;
static VALUE sym_gc_samples, objtracer;
static VALUE gc_hook;
static VALUE rb_mStackProf;

static void stackprof_newobj_handler(VALUE, void*);
static void stackprof_signal_handler(int sig, siginfo_t* sinfo, void* ucontext);
int64_t timeval_to_usec(struct timeval *diff);
int64_t diff_timevals_usec(struct timeval *start, struct timeval *end);

static VALUE
stackprof_start(int argc, VALUE *argv, VALUE self)
{
    struct sigaction sa;
    struct itimerval timer;
    VALUE opts = Qnil, mode = Qnil, interval = Qnil, out = Qfalse, debug = Qfalse;
    int raw = 0, aggregate = 1;

    if (_stackprof.running)
	return Qfalse;

    gettimeofday(&_stackprof.started_at, NULL);

    rb_scan_args(argc, argv, "0:", &opts);

    if (RTEST(opts)) {
	mode = rb_hash_aref(opts, sym_mode);
	interval = rb_hash_aref(opts, sym_interval);
	out = rb_hash_aref(opts, sym_out);
	debug = rb_hash_aref(opts, sym_debug);

	if (RTEST(rb_hash_aref(opts, sym_raw)))
	    raw = 1;
	if (rb_hash_lookup2(opts, sym_aggregate, Qundef) == Qfalse)
	    aggregate = 0;
    }
    _stackprof.debug = RTEST(debug);

    if (!RTEST(mode)) mode = sym_wall;

    // profiling can be paused and resumed, so allow for existing frames
    if (!_stackprof.frames) {
	_stackprof.frames = st_init_numtable();
	_stackprof.overall_signals = 0;
	_stackprof.overall_samples = 0;
	_stackprof.during_gc = 0;
	_stackprof.in_signal_handler = 0;
	_stackprof.last_sample_at = _stackprof.started_at;
    }

    if (mode == sym_object) {
	if (!RTEST(interval)) interval = INT2FIX(1);

	objtracer = rb_tracepoint_new(Qnil, RUBY_INTERNAL_EVENT_NEWOBJ, stackprof_newobj_handler, 0);
	rb_tracepoint_enable(objtracer);
    } else if (mode == sym_wall || mode == sym_cpu) {
	if (!RTEST(interval)) interval = INT2FIX(1000);

	sa.sa_sigaction = stackprof_signal_handler;
	sa.sa_flags = SA_RESTART | SA_SIGINFO;
	sigemptyset(&sa.sa_mask);
	sigaction(mode == sym_wall ? SIGALRM : SIGPROF, &sa, NULL);

	timer.it_interval.tv_sec = 0;
	timer.it_interval.tv_usec = NUM2INT(interval);
	timer.it_value = timer.it_interval;
	setitimer(mode == sym_wall ? ITIMER_REAL : ITIMER_PROF, &timer, 0);

        if (_stackprof.debug) {
            printf("started with interval %d (%ld sec %d usec)\n",
                NUM2INT(interval), timer.it_interval.tv_sec, timer.it_interval.tv_usec);
        }
    } else if (mode == sym_custom) {
	/* sampled manually */
	interval = Qnil;
    } else {
	rb_raise(rb_eArgError, "unknown profiler mode");
    }

    _stackprof.running = 1;
    _stackprof.raw = raw;
    _stackprof.aggregate = aggregate;
    _stackprof.mode = mode;
    _stackprof.interval = interval;
    _stackprof.out = out;

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
	_stackprof.in_signal_handler = 0;
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

    if (frame == _stackprof.fake_gc_frame) {
	name = _stackprof.fake_gc_frame_name;
	file = _stackprof.empty_string;
	line = INT2FIX(0);
    } else {
	name = rb_profile_frame_full_label(frame);

	file = rb_profile_frame_absolute_path(frame);
	if (NIL_P(file))
	    file = rb_profile_frame_path(frame);
	line = rb_profile_frame_first_lineno(frame);
    }

    rb_hash_aset(details, sym_name, name);
    rb_hash_aset(details, sym_file, file);
    if (line != INT2FIX(0)) {
	rb_hash_aset(details, sym_line, line);
    }

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
stackprof_results(int argc, VALUE *argv, VALUE self)
{
    VALUE results, frames;

    if (!_stackprof.frames || _stackprof.running)
	return Qnil;

    results = rb_hash_new();
    rb_hash_aset(results, sym_version, DBL2NUM(1.2));
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

    if (_stackprof.raw && _stackprof.raw_samples_len) {
	size_t len, n, o;
	VALUE raw_timestamp_deltas;
	VALUE raw_samples = rb_ary_new_capa(_stackprof.raw_samples_len);

	for (n = 0; n < _stackprof.raw_samples_len; n++) {
	    len = (size_t)_stackprof.raw_samples[n];
	    rb_ary_push(raw_samples, SIZET2NUM(len));

	    for (o = 0, n++; o < len; n++, o++)
		rb_ary_push(raw_samples, rb_obj_id(_stackprof.raw_samples[n]));
	    rb_ary_push(raw_samples, SIZET2NUM((size_t)_stackprof.raw_samples[n]));
	}

	free(_stackprof.raw_samples);
	_stackprof.raw_samples = NULL;
	_stackprof.raw_samples_len = 0;
	_stackprof.raw_samples_capa = 0;
	_stackprof.raw_sample_index = 0;

	rb_hash_aset(results, sym_raw, raw_samples);

	raw_timestamp_deltas = rb_ary_new_capa(_stackprof.raw_timestamp_deltas_len);

	for (n = 0; n < _stackprof.raw_timestamp_deltas_len; n++) {
	    rb_ary_push(raw_timestamp_deltas, INT2FIX(_stackprof.raw_timestamp_deltas[n]));
	}

	free(_stackprof.raw_timestamp_deltas);
	_stackprof.raw_timestamp_deltas = NULL;
	_stackprof.raw_timestamp_deltas_len = 0;
	_stackprof.raw_timestamp_deltas_capa = 0;

	rb_hash_aset(results, sym_raw_timestamp_deltas, raw_timestamp_deltas);

	_stackprof.raw = 0;
    }

    if (argc == 1)
	_stackprof.out = argv[0];

    if (RTEST(_stackprof.out)) {
	VALUE file;
	if (rb_respond_to(_stackprof.out, rb_intern("to_io"))) {
	    file = rb_io_check_io(_stackprof.out);
	} else {
	    file = rb_file_open_str(_stackprof.out, "w");
	}

	rb_marshal_dump(results, file);
	rb_io_flush(file);
	_stackprof.out = Qnil;
	return file;
    } else {
	return results;
    }
}

static VALUE
stackprof_run(int argc, VALUE *argv, VALUE self)
{
    rb_need_block();
    stackprof_start(argc, argv, self);
    rb_ensure(rb_yield, Qundef, stackprof_stop, self);
    return stackprof_results(0, 0, self);
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

/*
    Records information about the frames captured in `_stackprof.frames_buffer`,
    up to `frame_count-1` (buffer may contain more frames from prior sample),
    captured `timestamp_delta` microseconds after previous sample.
*/
void
stackprof_record_sample_for_stack(int frame_count, int64_t timestamp_delta)
{
    int i, n;
    VALUE prev_frame = Qnil;

    _stackprof.overall_samples++;

    if (_stackprof.raw) {
	int found = 0;

	/* If there's no sample buffer allocated, then allocate one.  The buffer
	 * format is the number of frames (frame_count), then the list of frames (from
	 * `_stackprof.raw_samples`), followed by the number of times this
	 * particular stack has been seen in a row.  Each "new" stack is added
	 * to the end of the buffer, but if the previous stack is the same as
	 * the current stack, the counter will be incremented. */
	if (!_stackprof.raw_samples) {
	    _stackprof.raw_samples_capa = frame_count * 100;
	    _stackprof.raw_samples = malloc(sizeof(VALUE) * _stackprof.raw_samples_capa);
	}

	/* If we can't fit all the samples in the buffer, double the buffer size. */
	while (_stackprof.raw_samples_capa <= _stackprof.raw_samples_len + (frame_count + 2)) {
	    _stackprof.raw_samples_capa *= 2;
	    _stackprof.raw_samples = realloc(_stackprof.raw_samples, sizeof(VALUE) * _stackprof.raw_samples_capa);
	}

	/* If we've seen this stack before in the last sample, then increment the "seen" count. */
	if (_stackprof.raw_samples_len > 0 && _stackprof.raw_samples[_stackprof.raw_sample_index] == (VALUE)frame_count) {
	    /* The number of samples could have been the same, but the stack
	     * might be different, so we need to check the stack here.  Stacks
	     * in the raw buffer are stored in the opposite direction of stacks
	     * in the frames buffer that came from Ruby. */
	    for (i = frame_count-1, n = 0; i >= 0; i--, n++) {
		VALUE frame = _stackprof.frames_buffer[i];
		if (_stackprof.raw_samples[_stackprof.raw_sample_index + 1 + n] != frame)
		    break;
	    }
	    if (i == -1) {
		_stackprof.raw_samples[_stackprof.raw_samples_len-1] += 1;
		found = 1;
	    }
	}

	/* If we haven't seen the stack, then add it to the buffer along with
	 * the length of the stack and a 1 for the "seen" count */
	if (!found) {
	    /* Bump the `raw_sample_index` up so that the next iteration can
	     * find the previously recorded stack size. */
	    _stackprof.raw_sample_index = _stackprof.raw_samples_len;
	    _stackprof.raw_samples[_stackprof.raw_samples_len++] = (VALUE)frame_count;
	    for (i = frame_count-1; i >= 0; i--) {
		VALUE frame = _stackprof.frames_buffer[i];
		_stackprof.raw_samples[_stackprof.raw_samples_len++] = frame;
	    }
	    _stackprof.raw_samples[_stackprof.raw_samples_len++] = (VALUE)1;
	}

	/* If there's no timestamp delta buffer, allocate one */
	if (!_stackprof.raw_timestamp_deltas) {
	    _stackprof.raw_timestamp_deltas_capa = 100;
	    _stackprof.raw_timestamp_deltas = malloc(sizeof(int) * _stackprof.raw_timestamp_deltas_capa);
	    _stackprof.raw_timestamp_deltas_len = 0;
	}

	/* Double the buffer size if it's too small */
	while (_stackprof.raw_timestamp_deltas_capa <= _stackprof.raw_timestamp_deltas_len + 1) {
	    _stackprof.raw_timestamp_deltas_capa *= 2;
	    _stackprof.raw_timestamp_deltas = realloc(_stackprof.raw_timestamp_deltas, sizeof(int) * _stackprof.raw_timestamp_deltas_capa);
	}

	/* Store the time delta (which is the amount of time between samples) */
	_stackprof.raw_timestamp_deltas[_stackprof.raw_timestamp_deltas_len++] = timestamp_delta;
    }

    for (i = 0; i < frame_count; i++) {
	int line = _stackprof.lines_buffer[i];
	VALUE frame = _stackprof.frames_buffer[i];
	frame_data_t *frame_data = sample_for(frame);

	if (frame_data->seen_at_sample_number != _stackprof.overall_samples) {
	    frame_data->total_samples++;
	}
	frame_data->seen_at_sample_number = _stackprof.overall_samples;

	if (i == 0) {
	    frame_data->caller_samples++;
	} else if (_stackprof.aggregate) {
	    if (!frame_data->edges)
		frame_data->edges = st_init_numtable();
	    st_numtable_increment(frame_data->edges, (st_data_t)prev_frame, 1);
	}

	if (_stackprof.aggregate && line > 0) {
	    size_t half = (size_t)1<<(8*SIZEOF_SIZE_T/2);
	    size_t increment = i == 0 ? half + 1 : half;
	    if (!frame_data->lines)
		frame_data->lines = st_init_numtable();
	    st_numtable_increment(frame_data->lines, (st_data_t)line, increment);
	}

	prev_frame = frame;
    }

    gettimeofday(&_stackprof.last_sample_at, NULL);
}

void
stackprof_record_sample()
{
    int frame_count;
    struct timeval sampling_start, sampling_finish;

    gettimeofday(&sampling_start, NULL);
    int64_t time_since_last_sample_usec = diff_timevals_usec(&_stackprof.last_sample_at, &sampling_start);

    if (_stackprof.debug) {
        int64_t time_since_start_usec = diff_timevals_usec(&_stackprof.started_at, &sampling_start);
        printf("timestamp delta %lld usec since last, %lld since start, with interval %d\n",
            time_since_last_sample_usec, time_since_start_usec, NUM2INT(_stackprof.interval));
    }

    frame_count = rb_profile_frames(0, sizeof(_stackprof.frames_buffer) / sizeof(VALUE), _stackprof.frames_buffer, _stackprof.lines_buffer);

    stackprof_record_sample_for_stack(frame_count, time_since_last_sample_usec);

    gettimeofday(&sampling_finish, NULL);
    _stackprof.last_sample_at = sampling_finish;

    if (_stackprof.debug) {
        int64_t sampling_duration_usec = diff_timevals_usec(&sampling_start, &sampling_finish);
        printf("duration of stackprof_record_sample: %ld usec with interval %d\n",
            sampling_duration_usec,
            NUM2INT(_stackprof.interval));

        if (sampling_duration_usec >= NUM2INT(_stackprof.interval)) {
            fprintf(stderr, "INTERVAL IS TOO FAST: %d with interval %d\n",
                sampling_duration_usec, NUM2INT(_stackprof.interval));
        }
    }
}

void
stackprof_record_gc_samples()
{
    int64_t delta_to_first_unrecorded_gc_sample = 0;
    int i;
    struct timeval t;
    struct timeval diff;
    gettimeofday(&t, NULL);
    timersub(&t, &_stackprof.last_sample_at, &diff);

    if (_stackprof.raw) {
	// We don't know when the GC samples were actually marked, so let's
	// assume that they were marked at a perfectly regular interval.
	delta_to_first_unrecorded_gc_sample = timeval_to_usec(&diff) - (_stackprof.unrecorded_gc_samples - 1) * NUM2INT(_stackprof.interval);
	if (delta_to_first_unrecorded_gc_sample < 0) {
	    delta_to_first_unrecorded_gc_sample = 0;
	}
    }

    _stackprof.frames_buffer[0] = _stackprof.fake_gc_frame;
    _stackprof.lines_buffer[0] = 0;

    for (i = 0; i < _stackprof.unrecorded_gc_samples; i++) {
	int64_t timestamp_delta = i == 0 ? delta_to_first_unrecorded_gc_sample : NUM2INT(_stackprof.interval);
	stackprof_record_sample_for_stack(1, timestamp_delta);
    }
    _stackprof.during_gc += _stackprof.unrecorded_gc_samples;
    _stackprof.unrecorded_gc_samples = 0;
}

static void
stackprof_gc_job_handler(void *data)
{
    if (_stackprof.in_signal_handler) return;
    if (!_stackprof.running) return;

    _stackprof.in_signal_handler++;
    stackprof_record_gc_samples();
    _stackprof.in_signal_handler--;
}

static void
stackprof_job_handler(void *data)
{
    if (_stackprof.in_signal_handler) return;
    if (!_stackprof.running) return;

    _stackprof.in_signal_handler++;
    stackprof_record_sample();
    _stackprof.in_signal_handler--;
}

static void
stackprof_signal_handler(int sig, siginfo_t *sinfo, void *ucontext)
{
    _stackprof.overall_signals++;

    // Protect against individual samples taking longer to capture than
    // the interval between samples, which would cause the job queue
    // to pile up faster than it's flushed, peg the CPU, and hang the program.
    if (_stackprof.in_signal_handler) {
        if (_stackprof.debug)
            fprintf(stderr, "skip stackprof_signal_handler, already in handler!\n");
        return;
    }

    if (rb_during_gc()) {
	_stackprof.unrecorded_gc_samples++;
	rb_postponed_job_register_one(0, stackprof_gc_job_handler, (void*)0);
    } else {
	rb_postponed_job_register_one(0, stackprof_job_handler, (void*)0);
    }
}

static void
stackprof_newobj_handler(VALUE tpval, void *data)
{
    _stackprof.overall_signals++;
    if (RTEST(_stackprof.interval) && _stackprof.overall_signals % NUM2INT(_stackprof.interval))
	return;
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
    if (RTEST(_stackprof.out))
	rb_gc_mark(_stackprof.out);

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
	    // TODO what if interval > 1 sec ??
	    timer.it_interval.tv_sec = 0;
	    timer.it_interval.tv_usec = NUM2INT(_stackprof.interval);
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

int64_t timeval_to_usec(struct timeval *diff) {
    return MICROSECONDS_IN_SECOND * diff->tv_sec + diff->tv_usec;
}

int64_t diff_timevals_usec(struct timeval *start, struct timeval *end) {
    struct timeval diff;
    if ((end->tv_usec - start->tv_usec) < 0) {
        diff.tv_sec = end->tv_sec - start->tv_sec - 1;
        diff.tv_usec = MICROSECONDS_IN_SECOND + end->tv_usec - start->tv_usec;
    } else {
        diff.tv_sec = end->tv_sec - start->tv_sec;
        diff.tv_usec = end->tv_usec - start->tv_usec;
    }
    return timeval_to_usec(&diff);
}

void
Init_stackprof(void)
{
#define S(name) sym_##name = ID2SYM(rb_intern(#name));
    S(object);
    S(custom);
    S(wall);
    S(cpu);
    S(name);
    S(file);
    S(line);
    S(total_samples);
    S(gc_samples);
    S(missed_samples);
    S(samples);
    S(edges);
    S(lines);
    S(version);
    S(mode);
    S(interval);
    S(raw);
    S(raw_timestamp_deltas);
    S(out);
    S(frames);
    S(aggregate);
    S(debug);
#undef S

    gc_hook = Data_Wrap_Struct(rb_cObject, stackprof_gc_mark, NULL, &_stackprof);
    rb_global_variable(&gc_hook);

    _stackprof.raw_samples = NULL;
    _stackprof.raw_samples_len = 0;
    _stackprof.raw_samples_capa = 0;
    _stackprof.raw_sample_index = 0;

    _stackprof.raw_timestamp_deltas = NULL;
    _stackprof.raw_timestamp_deltas_len = 0;
    _stackprof.raw_timestamp_deltas_capa = 0;

    _stackprof.fake_gc_frame = INT2FIX(0x9C);
    _stackprof.empty_string = rb_str_new_cstr("");
    _stackprof.fake_gc_frame_name = rb_str_new_cstr("(garbage collection)");
    rb_global_variable(&_stackprof.fake_gc_frame_name);
    rb_global_variable(&_stackprof.empty_string);

    rb_mStackProf = rb_define_module("StackProf");
    rb_define_singleton_method(rb_mStackProf, "running?", stackprof_running_p, 0);
    rb_define_singleton_method(rb_mStackProf, "run", stackprof_run, -1);
    rb_define_singleton_method(rb_mStackProf, "start", stackprof_start, -1);
    rb_define_singleton_method(rb_mStackProf, "stop", stackprof_stop, 0);
    rb_define_singleton_method(rb_mStackProf, "results", stackprof_results, -1);
    rb_define_singleton_method(rb_mStackProf, "sample", stackprof_sample, 0);

    pthread_atfork(stackprof_atfork_prepare, stackprof_atfork_parent, stackprof_atfork_child);
}
