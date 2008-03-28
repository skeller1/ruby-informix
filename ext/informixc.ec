/* $Id: informixc.ec,v 1.6 2008/03/28 08:29:06 santana Exp $ */
/*
* Copyright (c) 2006-2008, Gerardo Santana Gomez Garrido <gerardo.santana@gmail.com>
 * All rights reserved.
 * 
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 * 3. The name of the author may not be used to endorse or promote products
 *    derived from this software without specific prior written permission.
 * 
 * THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
 * IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 * WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT,
 * INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 * (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
 * SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
 * HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
 * STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN
 * ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
 * POSSIBILITY OF SUCH DAMAGE.
 */

static const char rcsid[] = "$Id: informixc.ec,v 1.6 2008/03/28 08:29:06 santana Exp $";

#include "ruby.h"

#include <sqlstype.h>
#include <sqltypes.h>

static VALUE rb_cDate, rb_cBigDecimal, rb_cRational;

/* Modules */
static VALUE rb_mInformix;
static VALUE rb_mInterval;
static VALUE rb_mSequentialCursor;
static VALUE rb_mScrollCursor;
static VALUE rb_mInsertCursor;

/* Classes */
static VALUE rb_cSlob, rb_cSlobStat;
static VALUE rb_cDatabase;
static VALUE rb_cStatement;
static VALUE rb_cCursor;

/* Exceptions */
static VALUE rb_eError, rb_eWarning, rb_eInternalError;
static VALUE rb_eProgrammingError, rb_eOperationalError, rb_eDatabaseError;

static ID s_read, s_new, s_utc, s_day, s_month, s_year;
static ID s_hour, s_min, s_sec, s_usec, s_to_s, s_to_i;
static ID s_add_info, s_qual, s_from_months, s_from_seconds;
static ID s_add, s_mul;

static VALUE sym_name, sym_type, sym_nullable, sym_stype, sym_length;
static VALUE sym_precision, sym_scale, sym_default, sym_xid;
static VALUE sym_scroll, sym_hold;
static VALUE sym_col_info, sym_sbspace, sym_estbytes, sym_extsz;
static VALUE sym_createflags, sym_openflags, sym_maxbytes;
static VALUE sym_params;
static VALUE sym_YEAR_TO_MONTH;

#define IDSIZE 30

typedef struct {
	short is_select, is_open;
	struct sqlda daInput, *daOutput;
	short *indInput, *indOutput;
	char *bfOutput;
	char cursor_id[IDSIZE];
	char stmt_id[IDSIZE];
	VALUE db, array, hash, field_names;
	char *database_id;
} cursor_t;

typedef struct {
	mint fd;
	ifx_lo_t lo;
	ifx_lo_create_spec_t *spec;
	short type; /* XID_CLOB/XID_BLOB */
	VALUE db;
	char *database_id;
} slob_t;

typedef struct {
	mint atime, ctime, mtime, refcnt;
	ifx_int8_t size;
} slobstat_t;

#define NUM2INT8(num, int8addr) \
do { \
	VALUE str = rb_funcall(num, s_to_s, 0); \
	char *c_str = StringValueCStr(str); \
	mint ret = ifx_int8cvasc(c_str, strlen(c_str), (int8addr)); \
	if (ret < 0) \
		rb_raise(rb_eOperationalError, "Could not convert %s to INT8 [Error %d]", c_str, ret); \
} while(0)

#define INT82NUM(int8addr, num) \
do { \
	char str[21]; \
	mint ret; \
	ifx_int8toasc((int8addr), str, sizeof(str) - 1); \
	if (ret < 0) \
		rb_raise(rb_eOperationalError, \
			"Unable to convert INT8 to Bignum [Error %d]", ret); \
	str[sizeof(str) - 1] = 0; \
	num = rb_cstr2inum(str, 10); \
} while(0)

/*
 *****************************************************************************
 * Begins code copyrighted by Edwin M. Fine
 *****************************************************************************
 *
 * Copyright (c) 2006, 2007 Edwin M. Fine <efine@finecomputerconsultants.com>
 * All rights reserved.
 * 
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 * 3. The name of the author may not be used to endorse or promote products
 *    derived from this software without specific prior written permission.
 * 
 * THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
 * IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 * WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT,
 * INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 * (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
 * SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
 * HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
 * STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN
 * ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
 * POSSIBILITY OF SUCH DAMAGE.
 *****************************************************************************
 */
#define TRIM_BLANKS(s) ((s)[byleng(s, stleng(s))] = '\0')
#define NUM_ELEMS(arr) (sizeof(arr) / sizeof(*arr))

static VALUE
rbifx_ext_exception(VALUE exception_class)
{
	VALUE new_instance;

	EXEC SQL BEGIN DECLARE SECTION;
	/* All field sizes defined in IBM Informix ESQL/C Programmer's Manual */
	int4 sql_code;

	char sql_state[5 + 1];
	char class_origin_val[255 + 1];
	char subclass_origin_val[255 + 1];
	char message[8191 + 1];
	char server_name[255 + 1];
	char connection_name[255 + 1];

	mint sql_exception_number;
	mint exc_count = 0;
	mint message_len;
	mint i;
	EXEC SQL END DECLARE SECTION;

    new_instance = rb_class_new_instance(0, 0, exception_class);

    /* Check that instance of exception_class is derived from
     * Informix::Error
     */
    if (!rb_obj_is_kind_of(new_instance, rb_eError) &&
        !rb_obj_is_kind_of(new_instance, rb_eWarning)) {
        rb_raise(rb_eRuntimeError,
                "Can't instantiate exception from %s, only from %s or %s or their children",
                rb_class2name(exception_class),
                rb_class2name(rb_eWarning),
                rb_class2name(rb_eError));
    }
    
    EXEC SQL GET DIAGNOSTICS :exc_count = NUMBER;

    if (exc_count == 0) { /* Something went wrong */
        char message[128];
        snprintf(message,
                 sizeof(message),
                 "SQL ERROR: SQLCODE %d (sorry, no GET DIAGNOSTICS information available)",
                 SQLCODE);

        {
            VALUE argv[] = { rb_str_new2(message) };
            return rb_class_new_instance(NUM_ELEMS(argv), argv, rb_eOperationalError);
        }
    }

    for (i = 0; i < exc_count; ++i) {
        sql_exception_number = i + 1;

        EXEC SQL GET DIAGNOSTICS EXCEPTION :sql_exception_number
            :sql_code            = INFORMIX_SQLCODE,
            :sql_state           = RETURNED_SQLSTATE,
            :class_origin_val    = CLASS_ORIGIN,
            :subclass_origin_val = SUBCLASS_ORIGIN,
            :message             = MESSAGE_TEXT,
            :message_len         = MESSAGE_LENGTH,
            :server_name         = SERVER_NAME,
            :connection_name     = CONNECTION_NAME
            ;
        
        TRIM_BLANKS(class_origin_val);
        TRIM_BLANKS(subclass_origin_val);
        TRIM_BLANKS(server_name);
        TRIM_BLANKS(connection_name);
        message[message_len - 1] = '\0';
        TRIM_BLANKS(message);

        {
            VALUE sprintf_args[] = { rb_str_new2(message), rb_str_new2(sqlca.sqlerrm) };
            VALUE argv[] = {
                INT2FIX(sql_code),
                rb_str_new2(sql_state),
                rb_str_new2(class_origin_val),
                rb_str_new2(subclass_origin_val),
                rb_f_sprintf(NUM_ELEMS(sprintf_args), sprintf_args),
                rb_str_new2(server_name),
                rb_str_new2(connection_name)
            };

			rb_funcall(new_instance, s_add_info, 1, rb_ary_new4(7, argv));
        }
    }
    
    return new_instance;
}

/*
 * C helper functions (see ifx_except.h for documentation)
 */
static void
raise_ifx_extended(void)
{
    rb_exc_raise(rbifx_ext_exception(rb_eDatabaseError));
}
/*
 *****************************************************************************
 * Ends code copyrighted by Edwin M. Fine
 *****************************************************************************
 */

/* class Slob::Stat ------------------------------------------------------ */

static void
slobstat_free(slobstat_t *stat)
{
	xfree(stat);
}

static VALUE
slobstat_alloc(VALUE klass)
{
	slobstat_t *stat;

	stat = ALLOC(slobstat_t);
	return Data_Wrap_Struct(klass, 0, slobstat_free, stat);
}

/*
 * call-seq:
 * Slob::Stat.new(slob)  => stat
 *
 * Creates an Slob::Stat object with status information for the given Slob
 * object.
 */
static VALUE
rb_slobstat_initialize(VALUE self, VALUE slob)
{
	mint ret;
	slob_t *sb;
	slobstat_t *stat;
	ifx_lo_stat_t *st;
	EXEC SQL begin declare section;
		char *did;
	EXEC SQL end   declare section;

	Data_Get_Struct(slob, slob_t, sb);
	Data_Get_Struct(self, slobstat_t, stat);

	if (sb->fd == -1)
		rb_raise(rb_eProgrammingError,
			"Open the Slob object before getting its status");

	did = sb->database_id;
	EXEC SQL set connection :did;
	if (SQLCODE < 0)
		raise_ifx_extended();

	ret = ifx_lo_stat(sb->fd, &st);

	if (ret < 0)
		raise_ifx_extended();

	stat->atime = ifx_lo_stat_atime(st);
	stat->ctime = ifx_lo_stat_ctime(st);
	stat->mtime = ifx_lo_stat_mtime_sec(st);
	stat->refcnt = ifx_lo_stat_refcnt(st);
	ret = ifx_lo_stat_size(st, &stat->size);

	ifx_lo_stat_free(st);

	if (stat->atime == -1 || stat->ctime == -1 || stat->mtime == -1 ||
	    stat->refcnt == -1 || ret == -1) {
		rb_raise(rb_eOperationalError, "Unable to get status");
	}

	return self;
}

/*
 * call-seq:
 * stat <=> other_stat  => -1, 0, 1
 *
 * Compares with another <code>Slob::Stat</code> object by comparing their
 * modification times.
 */
static VALUE
rb_slobstat_cmp(VALUE self, VALUE other)
{
	if (rb_obj_is_kind_of(other, rb_obj_class(self))) {
		slobstat_t *stat;
		time_t t1, t2;

		Data_Get_Struct(self, slobstat_t, stat);  t1 = stat->mtime;
		Data_Get_Struct(other, slobstat_t, stat); t2 = stat->mtime;

		if (t1 == t2)
			return INT2FIX(0);
		else if (t1 < t2)
			return INT2FIX(-1);
		else
			return INT2FIX(1);
	}

	return Qnil;
}

/*
 * call-seq:
 * stat.atime  => time
 *
 * Returns the time of last access as a Time object.
 */
static VALUE
rb_slobstat_atime(VALUE self)
{
	slobstat_t *stat;

	Data_Get_Struct(self, slobstat_t, stat);
	return rb_time_new(stat->atime, 0);
}

/*
 * call-seq:
 * stat.ctime  => time
 *
 * Returns the time of last change in status as a Time object.
 */
static VALUE
rb_slobstat_ctime(VALUE self)
{
	slobstat_t *stat;

	Data_Get_Struct(self, slobstat_t, stat);
	return rb_time_new(stat->ctime, 0);
}

/*
 * call-seq:
 * stat.mtime  => time
 *
 * Returns the time of last modification as a Time object.
 */
static VALUE
rb_slobstat_mtime(VALUE self)
{
	slobstat_t *stat;

	Data_Get_Struct(self, slobstat_t, stat);
	return rb_time_new(stat->mtime, 0);
}

/*
 * call-seq:
 * stat.refcnt  => fixnum
 *
 * Returns the number of references
 */
static VALUE
rb_slobstat_refcnt(VALUE self)
{
	slobstat_t *stat;

	Data_Get_Struct(self, slobstat_t, stat);
	return INT2FIX(stat->refcnt);
}

/*
 * call-seq:
 * stat.size  => fixnum or bignum
 *
 * Returns the size in bytes
 */
static VALUE
rb_slobstat_size(VALUE self)
{
	slobstat_t *stat;
	VALUE size;

	Data_Get_Struct(self, slobstat_t, stat);
	INT82NUM(&stat->size, size);

	return size;
}

/* class Slob ------------------------------------------------------------ */

static void
slob_mark(slob_t *slob)
{
	rb_gc_mark(slob->db);
}

static void
slob_free(slob_t *slob)
{
	if (slob->fd != -1) {
		EXEC SQL begin declare section;
			char *did;
		EXEC SQL end   declare section;

		did = slob->database_id;
		EXEC SQL set connection :did;
		if (SQLCODE >= 0)
			ifx_lo_close(slob->fd);
	}

	if (slob->spec)
		ifx_lo_spec_free(slob->spec);

	xfree(slob);
}

static VALUE
slob_alloc(VALUE klass)
{
	slob_t *slob;

	slob = ALLOC(slob_t);
	slob->spec = NULL;
	slob->fd = -1;
	slob->database_id = NULL;
	slob->type = XID_CLOB;
	slob->db = 0;

	return Data_Wrap_Struct(klass, slob_mark, slob_free, slob);
}

/* :nodoc: */
static VALUE
rb_slob_initialize(int argc, VALUE *argv, VALUE self)
{
	mint ret, error;
	slob_t *slob;
	VALUE db, type, options;
	VALUE col_info, sbspace, estbytes, extsz, createflags, openflags, maxbytes;
	EXEC SQL begin declare section;
		char *did;
	EXEC SQL end   declare section;

	rb_scan_args(argc, argv, "12", &db, &type, &options);
	Data_Get_Struct(db, char, did);

	EXEC SQL set connection :did;
	if (SQLCODE < 0)
		raise_ifx_extended();

	Data_Get_Struct(self, slob_t, slob);
	slob->db = db;
	slob->database_id = did;

	if (!NIL_P(type)) {
		int t = FIX2INT(type);
		if (t != XID_CLOB && t != XID_BLOB)
			rb_raise(rb_eInternalError, "Invalid type %d for an SLOB", t);
		slob->type = t;
	}

	col_info = sbspace = estbytes = extsz = createflags = openflags = maxbytes = Qnil;

	if (!NIL_P(options)) {
		Check_Type(options, T_HASH);
		col_info = rb_hash_aref(options, sym_col_info);
		sbspace = rb_hash_aref(options, sym_sbspace);
		estbytes = rb_hash_aref(options, sym_estbytes);
		extsz = rb_hash_aref(options, sym_extsz);
		createflags = rb_hash_aref(options, sym_createflags);
		openflags = rb_hash_aref(options, sym_openflags);
		maxbytes = rb_hash_aref(options, sym_maxbytes);
	}

	ret = ifx_lo_def_create_spec(&slob->spec);
	if (ret < 0)
		raise_ifx_extended();

	if (!NIL_P(col_info)) {
		ret = ifx_lo_col_info(StringValueCStr(col_info), slob->spec);

		if (ret < 0)
			raise_ifx_extended();
	}
	if (!NIL_P(sbspace)) {
		char *c_sbspace = StringValueCStr(sbspace);
		ret = ifx_lo_specset_sbspace(slob->spec, c_sbspace);
		if (ret == -1)
			rb_raise(rb_eOperationalError, "Could not set sbspace name to %s", c_sbspace);
	}
	if (!NIL_P(estbytes)) {
		ifx_int8_t estbytes8;

		NUM2INT8(estbytes, &estbytes8);
		ret = ifx_lo_specset_estbytes(slob->spec, &estbytes8);
		if (ret == -1)
			rb_raise(rb_eOperationalError, "Could not set estbytes");
	}
	if (!NIL_P(extsz)) {
		ret = ifx_lo_specset_extsz(slob->spec, FIX2LONG(extsz));
		if (ret == -1)
			rb_raise(rb_eOperationalError, "Could not set extsz to %ld", FIX2LONG(extsz));
	}
	if (!NIL_P(createflags)) {
		ret = ifx_lo_specset_flags(slob->spec, FIX2LONG(createflags));
		if (ret == -1)
			rb_raise(rb_eOperationalError, "Could not set crate-time flags to 0x%X", FIX2LONG(createflags));
	}
	if (!NIL_P(maxbytes)) {
		ifx_int8_t maxbytes8;

		NUM2INT8(maxbytes, (&maxbytes8));
		ret = ifx_lo_specset_maxbytes(slob->spec, &maxbytes8);
		if (ret == -1)
			rb_raise(rb_eOperationalError, "Could not set maxbytes");
	}

	slob->fd = ifx_lo_create(slob->spec, RTEST(openflags)? FIX2LONG(openflags): LO_RDWR, &slob->lo, &error);
	if (slob->fd == -1)
		raise_ifx_extended();

	return self;
}

static VALUE rb_slob_close(VALUE self);
/*
 * call-seq:
 * Slob.new(database, type = Slob::CLOB, options = nil)                  => slob
 * Slob.new(database, type = Slob::CLOB, options = nil) {|slob| block }  => obj
 *
 * Creates a Smart Large Object of type <i>type</i> in <i>database</i>.
 * Returns a <code>Slob</code> object pointing to it.
 *
 * <i>type</i> can be Slob::BLOB or Slob::CLOB
 *
 * <i>options</i> can be nil or a Hash object with the following possible keys:
 *
 *   :sbspace     => Sbspace name
 *   :estbytes    => Estimated size, in bytes
 *   :extsz       => Allocation extent size
 *   :createflags => Create-time flags
 *   :openflags   => Access mode
 *   :maxbytes    => Maximum size
 *   :col_info    => Get the previous values from the column-level storage
 *                   characteristics for the specified database column
 */
static VALUE
rb_slob_s_new(int argc, VALUE *argv, VALUE klass)
{
	VALUE slob;

	slob = rb_class_new_instance(argc, argv, klass);

	if (rb_block_given_p())
		return rb_ensure(rb_yield, slob, rb_slob_close, slob);

	return slob;
}

/*
 * call-seq:
 * slob.open(access = Slob::RDONLY)  => slob
 *
 * Opens the Smart Large Object in <i>access</i> mode.
 *
 * Access modes:
 * 
 * Slob::RDONLY::		Read only
 * Slob::DIRTY_READ::	Read uncommitted data
 * Slob::WRONLY::	Write only
 * Slob::APPEND::	Append data to the end, if combined with RDWR or WRONLY; read only otherwise
 * Slob::RDWR::		Read/Write
 * Slob::BUFFER::	Use standard database server buffer pool
 * Slob::NOBUFFER::	Use private buffer from the session pool of the database server
 * Slob::LOCKALL::		Lock the entire Smart Large Object
 * Slob::LOCKRANGE::	Lock a range of bytes
 *
 * Returns __self__.
 */
static VALUE
rb_slob_open(int argc, VALUE *argv, VALUE self)
{
	VALUE access;
	slob_t *slob;
	mint error;
	EXEC SQL begin declare section;
		char *did;
	EXEC SQL end   declare section;

	Data_Get_Struct(self, slob_t, slob);

	if (slob->fd != -1) /* Already open */
		return self;

	did = slob->database_id;
	EXEC SQL set connection :did;
	if (SQLCODE < 0)
		raise_ifx_extended();

	rb_scan_args(argc, argv, "01", &access);

	slob->fd = ifx_lo_open(&slob->lo, NIL_P(access)? LO_RDONLY: FIX2INT(access), &error);

	if (slob->fd == -1)
		raise_ifx_extended();

	return self;
}

/*
 * call-seq:
 * slob.close  => slob
 * 
 * Closes the Smart Large Object and returns __self__.
 */
static VALUE
rb_slob_close(VALUE self)
{
	slob_t *slob;

	Data_Get_Struct(self, slob_t, slob);
	if (slob->fd != -1) {
		EXEC SQL begin declare section;
			char *did;
		EXEC SQL end   declare section;

		did = slob->database_id;
		EXEC SQL set connection :did;
		if (SQLCODE < 0)
			return self;

		ifx_lo_close(slob->fd);
		slob->fd = -1;
	}

	return self;
}

/*
 * call-seq:
 * slob.read(nbytes)  => string
 * 
 * Reads at most <i>nbytes</i> bytes from the Smart Large Object.
 *
 * Returns the bytes read as a String object.
 */
static VALUE
rb_slob_read(VALUE self, VALUE nbytes)
{
	slob_t *slob;
	mint error, ret;
	char *buffer;
	long c_nbytes;
	VALUE str;
	EXEC SQL begin declare section;
		char *did;
	EXEC SQL end   declare section;


	Data_Get_Struct(self, slob_t, slob);

	if (slob->fd == -1)
		rb_raise(rb_eProgrammingError, "Open the Slob object before reading");

	did = slob->database_id;
	EXEC SQL set connection :did;
	if (SQLCODE < 0)
		raise_ifx_extended();

	c_nbytes = FIX2LONG(nbytes);
	buffer = ALLOC_N(char, c_nbytes);
	ret = ifx_lo_read(slob->fd, buffer, c_nbytes, &error);

	if (ret == -1) {
		xfree(buffer);
		raise_ifx_extended();
	}

	str = rb_str_new(buffer, ret);
	xfree(buffer);

	return str;
}

/*
 * call-seq:
 * slob.write(data)  => fixnum or bignum
 * 
 * Writes <i>data</i> to the Smart Large Object. If <i>data</i> is not a
 * String object it will be converted to String using <code>to_s</code>.
 *
 * Returns the number of bytes written.
 */
static VALUE
rb_slob_write(VALUE self, VALUE data)
{
	slob_t *slob;
	mint error, ret;
	char *buffer;
	long nbytes;
	VALUE str;
	EXEC SQL begin declare section;
		char *did;
	EXEC SQL end   declare section;

	Data_Get_Struct(self, slob_t, slob);

	if (slob->fd == -1)
		rb_raise(rb_eProgrammingError, "Open the Slob object before writing");

	did = slob->database_id;
	EXEC SQL set connection :did;
	if (SQLCODE < 0)
		raise_ifx_extended();

	str = rb_obj_as_string(data);
	buffer = RSTRING_PTR(str);
	nbytes = RSTRING_LEN(str);

	ret = ifx_lo_write(slob->fd, buffer, nbytes, &error);

	if (ret == -1)
		raise_ifx_extended();

	return LONG2NUM(ret);
}

/*
 * call-seq:
 * slob << data   => slob
 *
 * Writes <i>data</i> to the Smart Large Object. If <i>data</i> is not a
 * String object it will be converted to String using <code>to_s</code>.
 *
 * Returns self.
 */
static VALUE
rb_slob_addstr(VALUE self, VALUE data)
{
	rb_slob_write(self, data);
	return self;
}

/*
 * call-seq:
 * slob.seek(offset, whence)  => fixnum or bignum
 * 
 * Sets the file position for the next read or write
 * operation on the open Smart Large Object.
 *
 *
 * <i>offset</i>	offset from the starting seek position
 * <i>whence</i>	identifies the starting seek position
 * 
 * Values for <i>whence</i>:
 *
 * Slob::SEEK_SET::	The start of the Smart Large Object
 * Slob::SEEK_CUR::	The current seek position in the Smart Large Object
 * Slob::SEEK_END::	The end of the Smart Large Object
 *
 * Returns the new position.
 */
static VALUE
rb_slob_seek(VALUE self, VALUE offset, VALUE whence)
{
	slob_t *slob;
	mint ret;
	VALUE seek_pos;
	ifx_int8_t offset8, seek_pos8;
	EXEC SQL begin declare section;
		char *did;
	EXEC SQL end   declare section;

	Data_Get_Struct(self, slob_t, slob);

	if (slob->fd == -1)
		rb_raise(rb_eProgrammingError, "Open the Slob object first");

	did = slob->database_id;
	EXEC SQL set connection :did;
	if (SQLCODE < 0)
		raise_ifx_extended();

	NUM2INT8(offset, &offset8);
	ret = ifx_lo_seek(slob->fd, &offset8, FIX2INT(whence), &seek_pos8);
	if (ret < 0)
		raise_ifx_extended();

	INT82NUM(&seek_pos8, seek_pos);

	return seek_pos;
}

/*
 * call-seq:
 * slob.pos = integer    => integer
 *
 * Seeks to the given position (in bytes) in _slob_.
 */
static VALUE
rb_slob_set_pos(VALUE self, VALUE pos)
{
	return rb_slob_seek(self, pos, LO_SEEK_SET);
}

/*
 * call-seq:
 * slob.rewind  => fixnum
 *
 * Moves the cursor position to the start of the Smart Large Object.
 */
static VALUE
rb_slob_rewind(VALUE self)
{
	return rb_slob_seek(self, INT2FIX(0), LO_SEEK_SET);
}

/*
 * call-seq:
 * slob.tell  => integer
 * slob.pos   => integer
 * 
 * Returns the current file or seek position for an open Smart Large Object
 */
static VALUE
rb_slob_tell(VALUE self)
{
	slob_t *slob;
	mint ret;
	VALUE seek_pos;
	ifx_int8_t seek_pos8;
	EXEC SQL begin declare section;
		char *did;
	EXEC SQL end   declare section;

	Data_Get_Struct(self, slob_t, slob);

	if (slob->fd == -1)
		rb_raise(rb_eProgrammingError, "Open the Slob object first");

	did = slob->database_id;
	EXEC SQL set connection :did;
	if (SQLCODE < 0)
		raise_ifx_extended();

	ret = ifx_lo_tell(slob->fd, &seek_pos8);
	if (ret < 0)
		raise_ifx_extended();

	INT82NUM(&seek_pos8, seek_pos);

	return seek_pos;
}

/*
 * call-seq:
 * slob.truncate(offset)  => slob
 * 
 * Truncates a Smart Large Object at a specified byte position.
 *
 * Returns __self__.
 */
static VALUE
rb_slob_truncate(VALUE self, VALUE offset)
{
	slob_t *slob;
	mint ret;
	ifx_int8_t offset8;
	EXEC SQL begin declare section;
		char *did;
	EXEC SQL end   declare section;

	Data_Get_Struct(self, slob_t, slob);

	if (slob->fd == -1)
		rb_raise(rb_eProgrammingError, "Open the Slob object first");

	did = slob->database_id;
	EXEC SQL set connection :did;
	if (SQLCODE < 0)
		raise_ifx_extended();

	NUM2INT8(offset, &offset8);
	ret = ifx_lo_truncate(slob->fd, &offset8);
	if (ret < 0)
		raise_ifx_extended();

	return self;
}

/*
 * call-seq:
 * slob.stat  => stat
 *
 * Creates and returns an Slob::Stat object with status information for _slob_.
 */
static VALUE
rb_slob_stat(VALUE self)
{
	return rb_class_new_instance(1, &self, rb_cSlobStat);
}

/*
 * call-seq:
 * slob.lock(offset, whence, range, mode)  =>  slob
 *
 * Locks _range_ number of bytes, starting from _offset_ bytes from
 * _whence_, in _mode_ mode.
 *
 * Returns _self_.
 *
 * Possible values:
 *
 *   offset  =>  integer
 *   whence  =>  Slob::SEEK_SET, Slob::SEEK_CUR, Slob::SEEK_END
 *   range   =>  integer, Slob::CURRENT_END, Slob::MAX_END
 *   mode    =>  Slob::SHARED_MODE, Slob::EXCLUSIVE_MODE
 */
static VALUE
rb_slob_lock(VALUE self, VALUE offset, VALUE whence, VALUE range, VALUE mode)
{
	slob_t *slob;
	mint ret;
	ifx_int8_t offset8, range8;
	EXEC SQL begin declare section;
		char *did;
	EXEC SQL end   declare section;

	Data_Get_Struct(self, slob_t, slob);

	if (slob->fd == -1)
		rb_raise(rb_eProgrammingError, "Open the Slob object first");

	did = slob->database_id;
	EXEC SQL set connection :did;
	if (SQLCODE < 0)
		raise_ifx_extended();

	NUM2INT8(offset, &offset8);
	NUM2INT8(range, &range8);
	ret = ifx_lo_lock(slob->fd, &offset8, FIX2INT(whence), &range8, FIX2INT(mode));
	if (ret < 0)
		raise_ifx_extended();

	return self;
}

/*
 * call-seq:
 * slob.unlock(offset, whence, range)  =>  slob
 *
 * Unlocks _range_ number of bytes, starting from _offset_ bytes from
 * _whence_.
 *
 * Returns _self_.
 *
 * Possible values:
 *
 *   offset  =>  integer
 *   whence  =>  Slob::SEEK_SET, Slob::SEEK_CUR, Slob::SEEK_END
 *   range   =>  integer
 */
static VALUE
rb_slob_unlock(VALUE self, VALUE offset, VALUE whence, VALUE range)
{
	slob_t *slob;
	mint ret;
	ifx_int8_t offset8, range8;
	EXEC SQL begin declare section;
		char *did;
	EXEC SQL end   declare section;

	Data_Get_Struct(self, slob_t, slob);

	if (slob->fd == -1)
		rb_raise(rb_eProgrammingError, "Open the Slob object first");

	did = slob->database_id;
	EXEC SQL set connection :did;
	if (SQLCODE < 0)
		raise_ifx_extended();

	NUM2INT8(offset, &offset8);
	NUM2INT8(range, &range8);
	ret = ifx_lo_unlock(slob->fd, &offset8, FIX2INT(whence), &range8);
	if (ret < 0)
		raise_ifx_extended();

	return self;
}

typedef enum {
	slob_estbytes, slob_extsz, slob_flags, slob_maxbytes, slob_sbspace
} slob_option_t;
static char *str_slob_options[] = {
	"estbytes", "extsz", "flags", "maxbytes", "sbspace"};
/*
 * Base function for getting storage charasteristics
 */
static VALUE
slob_specget(VALUE self, slob_option_t option)
{
	slob_t *slob;
	mint ret;
	ifx_lo_stat_t *stat;
	ifx_lo_create_spec_t *spec;
	ifx_int8_t int8;
	char buffer[129];
	VALUE item;
	EXEC SQL begin declare section;
		char *did;
	EXEC SQL end   declare section;

	Data_Get_Struct(self, slob_t, slob);

	if (slob->fd == -1)
		rb_raise(rb_eProgrammingError, "Open the Slob object first");

	did = slob->database_id;
	EXEC SQL set connection :did;
	if (SQLCODE < 0)
		raise_ifx_extended();

	ret = ifx_lo_stat(slob->fd, &stat);
	if (ret < 0)
		raise_ifx_extended();

	spec = ifx_lo_stat_cspec(stat);
	if (spec == NULL) {
		ifx_lo_stat_free(stat);
		rb_raise(rb_eOperationalError, "Unable to get storage characteristics");
	}

	switch(option) {
	case slob_estbytes:
		ret = ifx_lo_specget_estbytes(spec, &int8);
		break;
	case slob_extsz:
		ret = ifx_lo_specget_extsz(spec);
		break;
	case slob_flags:
		ret = ifx_lo_specget_flags(spec);
		break;
	case slob_maxbytes:
		ret = ifx_lo_specget_maxbytes(spec, &int8);
		break;
	case slob_sbspace:
		ret = ifx_lo_specget_sbspace(spec, buffer, sizeof(buffer));
	}

	ifx_lo_stat_free(stat);
	if (ret == -1)
		rb_raise(rb_eOperationalError, "Unable to get information for %s", str_slob_options[option]);

	switch(option) {
	case slob_estbytes:
	case slob_maxbytes:
		INT82NUM(&int8, item);
		return item;
	case slob_extsz:
	case slob_flags:
		return INT2FIX(ret);
	case slob_sbspace:
		return rb_str_new2(buffer);
	}

	return Qnil; /* Not reached */
}

/*
 * Base function for setting extsz and flags
 */
static VALUE
slob_specset(VALUE self, slob_option_t option, VALUE value)
{
	slob_t *slob;
	mint ret;
	ifx_lo_stat_t *stat;
	ifx_lo_create_spec_t *spec;
	EXEC SQL begin declare section;
		char *did;
	EXEC SQL end   declare section;

	Data_Get_Struct(self, slob_t, slob);

	if (slob->fd == -1)
		rb_raise(rb_eProgrammingError, "Open the Slob object first");

	did = slob->database_id;
	EXEC SQL set connection :did;
	if (SQLCODE < 0)
		raise_ifx_extended();

	ret = ifx_lo_stat(slob->fd, &stat);
	if (ret < 0)
		raise_ifx_extended();

	spec = ifx_lo_stat_cspec(stat);
	if (spec == NULL) {
		ifx_lo_stat_free(stat);
		rb_raise(rb_eOperationalError, "Unable to get storage characteristics");
	}

	switch(option) {
	case slob_extsz:
		ret = ifx_lo_specset_extsz(spec, FIX2INT(value));
		break;
	case slob_flags:
		ret = ifx_lo_specset_flags(spec, FIX2INT(value));
		break;
	default:
		break; /* Not reached */
	}

	ifx_lo_stat_free(stat);
	if (ret == -1)
		rb_raise(rb_eOperationalError, "Unable to set information for %s", str_slob_options[option]);

	return value;
}

/*
 * call-seq:
 * slob.estbytes  => fixnum or bignum
 *
 * Returns the estimated size of the SLOB
 */
static VALUE
rb_slob_estbytes(VALUE self)
{
	return slob_specget(self, slob_estbytes);
}

/*
 * call-seq:
 * slob.extsz  => fixnum
 *
 * Returns the allocation extent size of the SLOB
 */
static VALUE
rb_slob_extsz(VALUE self)
{
	return slob_specget(self, slob_extsz);
}

/*
 * call-seq:
 * slob.flags  => fixnum
 *
 * Returns the create-time flags of the SLOB
 */
static VALUE
rb_slob_flags(VALUE self)
{
	return slob_specget(self, slob_flags);
}

/*
 * call-seq:
 * slob.maxbytes  => fixnum or bignum
 *
 * Returns the maximum size of the SLOB
 */
static VALUE
rb_slob_maxbytes(VALUE self)
{
	return slob_specget(self, slob_maxbytes);
}

/*
 * call-seq:
 * slob.sbspace  => string
 *
 * Returns the name of the sbspace where the SLOB is stored
 */
static VALUE
rb_slob_sbspace(VALUE self)
{
	return slob_specget(self, slob_sbspace);
}

/*
 * call-seq:
 * slob.extsz = fixnum    => fixnum
 *
 * Sets the allocation extent size for the SLOB
 */
static VALUE
rb_slob_set_extsz(VALUE self, VALUE value)
{
	return slob_specset(self, slob_extsz, value);
}

/*
 * call-seq:
 * slob.flags = fixnum    => fixnum
 *
 * Sets the create-time flags of the SLOB
 */
static VALUE
rb_slob_set_flags(VALUE self, VALUE value)
{
	return slob_specset(self, slob_flags, value);
}

typedef enum { slob_atime, slob_ctime, slob_mtime, slob_refcnt, slob_size } slob_stat_t;
static char *str_slob_stats[] = {
	"atime", "ctime", "mtime", "refcnt", "size"
};

/*
 * Base function for getting status information
 */
static VALUE
slob_stat(VALUE self, slob_stat_t stat)
{
	mint ret;
	slob_t *slob;
	ifx_lo_stat_t *st;
	ifx_int8_t int8;
	VALUE result;
	EXEC SQL begin declare section;
		char *did;
	EXEC SQL end   declare section;

	Data_Get_Struct(self, slob_t, slob);

	if (slob->fd == -1)
		rb_raise(rb_eProgrammingError,
			"Open the Slob object before getting its status");

	did = slob->database_id;
	EXEC SQL set connection :did;
	if (SQLCODE < 0)
		raise_ifx_extended();

	ret = ifx_lo_stat(slob->fd, &st);

	if (ret < 0)
		raise_ifx_extended();

	switch(stat) {
	case slob_atime:
		ret = ifx_lo_stat_atime(st);
		break;
	case slob_ctime:
		ret = ifx_lo_stat_ctime(st);
		break;
	case slob_mtime:
		ret = ifx_lo_stat_mtime_sec(st);
		break;
	case slob_refcnt:
		ret = ifx_lo_stat_refcnt(st);
		break;
	case slob_size:
		ret = ifx_lo_stat_size(st, &int8);
	}

	ifx_lo_stat_free(st);

	if (ret == -1)
		rb_raise(rb_eOperationalError, "Unable to get value of %s", str_slob_stats[stat]);

	switch(stat) {
		case slob_atime:
		case slob_ctime:
		case slob_mtime:
			return rb_time_new(ret, 0);
		case slob_refcnt:
			return INT2FIX(ret);
		case slob_size:
			INT82NUM(&int8, result);
			return result;
	}

	return Qnil; /* Not reached */
}

/*
 * call-seq:
 * slob.atime  => time
 *
 * Returns the time of last access as a Time object.
 */
static VALUE
rb_slob_atime(VALUE self)
{
	return slob_stat(self, slob_atime);
}

/*
 * call-seq:
 * stat.ctime  => time
 *
 * Returns the time of last change in status as a Time object.
 */
static VALUE
rb_slob_ctime(VALUE self)
{
	return slob_stat(self, slob_ctime);
}

/*
 * call-seq:
 * stat.mtime  => time
 *
 * Returns the time of last modification as a Time object.
 */
static VALUE
rb_slob_mtime(VALUE self)
{
	return slob_stat(self, slob_mtime);
}

/*
 * call-seq:
 * stat.refcnt  => fixnum
 *
 * Returns the number of references
 */
static VALUE
rb_slob_refcnt(VALUE self)
{
	return slob_stat(self, slob_refcnt);
}

/*
 * call-seq:
 * stat.size  => fixnum or bignum
 *
 * Returns the size in bytes
 */
static VALUE
rb_slob_size(VALUE self)
{
	return slob_stat(self, slob_size);
}

/* Helper functions ------------------------------------------------------- */

/*
 * Counts the number of markers '?' in the query
 */
static int
count_markers(const char *query)
{
	register char c, quote = 0;
	register int count = 0;

	while((c = *query++)) {
		if (quote && c != quote)
			;
		else if (quote == c) {
			quote = 0;
		}
		else if (c == '\'' || c == '"') {
			quote = c;
		}
		else if (c == '?') {
			++count;
		}
	}
	return count;
}

/*
 * Allocates memory for the indicators array and slots for the input
 * parameters, if any. Freed by free_input_slots.
 */
static void
alloc_input_slots(cursor_t *c, const char *query)
{
	register int n;

	n = count_markers(query);
	c->daInput.sqld = n;
	if (n) {
		c->daInput.sqlvar = ALLOC_N(struct sqlvar_struct, n);
		memset(c->daInput.sqlvar, 0, n*sizeof(struct sqlvar_struct));
		c->indInput = ALLOC_N(short, n);
		while(n--)
			c->daInput.sqlvar[n].sqlind = &c->indInput[n];
	}
	else {
		c->daInput.sqlvar = NULL;
		c->indInput = NULL;
	}
}

/*
 * Allocates memory for the output data slots and its indicators array.
 * Freed by free_output_slots.
 */
static void
alloc_output_slots(cursor_t *c)
{
	register int i, count;
	register short *ind;
	struct sqlvar_struct *var;
	register char *buffer;

	c->field_names = rb_ary_new2(c->daOutput->sqld);

	ind = c->indOutput = ALLOC_N(short, c->daOutput->sqld);

	var = c->daOutput->sqlvar;
	for (i = count = 0; i < c->daOutput->sqld; i++, ind++, var++) {
		var->sqlind = ind;
		rb_ary_store(c->field_names, i, rb_str_new2(var->sqlname));
		if (ISSMARTBLOB(var->sqltype, var->sqlxid)) {
			var->sqldata = (char *)ALLOC(ifx_lo_t);
			continue;
		}
		var->sqllen = rtypmsize(var->sqltype, var->sqllen);
		count = rtypalign(count, var->sqltype) + var->sqllen;
	}

	buffer = c->bfOutput = ALLOC_N(char, count);
	memset(buffer, 0, count);

	var = c->daOutput->sqlvar;
	for (i = count = 0; i < c->daOutput->sqld; i++, var++) {
		if (var->sqldata)
			continue;
		count = rtypalign(count, var->sqltype);
		var->sqldata = buffer + count;
		count += var->sqllen;
		if (ISBYTESTYPE(var->sqltype) || ISTEXTTYPE(var->sqltype)) {
			loc_t *p;
			p = (loc_t *)var->sqldata;
			byfill((char *)p, sizeof(loc_t), 0);
			p->loc_loctype = LOCMEMORY;
			p->loc_bufsize = -1;
		}
		if (var->sqltype == SQLDTIME || var->sqltype == SQLINTERVAL) {
			var->sqllen = 0;
		}
	}
}

/*
 * Frees the allocated memory of the input parameters, but not the slots
 * nor the indicators array. Allocated by bind_input_params.
 */
static void
clean_input_slots(cursor_t *c)
{
	register int count;
	register struct sqlvar_struct *var;

	if (c->daInput.sqlvar == NULL)
		return;
	var = c->daInput.sqlvar;
	count = c->daInput.sqld;
	while(count--) {
		if (var->sqldata != NULL) {
			if (var->sqltype == CLOCATORTYPE) {
				loc_t *p = (loc_t *)var->sqldata;
				if (p->loc_buffer != NULL) {
					xfree(p->loc_buffer);
				}
			}
			xfree(var->sqldata);
			var->sqldata = NULL;
			var++;
		}
	}
}

/*
 * Frees the memory for the input parameters, their slots, and the indicators
 * array. Allocated by alloc_input_slots and bind_input_params.
 */
static void
free_input_slots(cursor_t *c)
{
	clean_input_slots(c);
	if (c->daInput.sqlvar) {
		xfree(c->daInput.sqlvar);
		c->daInput.sqlvar = NULL;
		c->daInput.sqld = 0;
	}
	if (c->indInput) {
		xfree(c->indInput);
		c->indInput = NULL;
	}
}

/*
 * Frees the memory for the output parameters, their slots, and the indicators
 * array. Allocated by alloc_output_slots.
 */
static void
free_output_slots(cursor_t *c)
{
	if (c->daOutput != NULL) {
		struct sqlvar_struct *var = c->daOutput->sqlvar;
		if (var) {
			register int i;
			for (i = 0; i < c->daOutput->sqld; i++, var++) {
				if (ISBLOBTYPE(var->sqltype)) {
					loc_t *p = (loc_t *) var->sqldata;
					if(p -> loc_buffer)
						xfree(p->loc_buffer);
				}
				if (ISSMARTBLOB(var->sqltype, var->sqlxid))
					xfree(var->sqldata);
			}
		}
		xfree(c->daOutput);
		c->daOutput = NULL;
	}
	if (c->indOutput != NULL) {
		xfree(c->indOutput);
		c->indOutput = NULL;
	}
	if (c->bfOutput != NULL) {
		xfree(c->bfOutput);
		c->bfOutput = NULL;
	}
}

/*
 * Gets an array of Ruby objects as input parameters and place them in input
 * slots, converting data types and allocating memory as needed.
 */
static void
bind_input_params(cursor_t *c, VALUE *argv)
{
	VALUE data, klass;
	register int i;
	register struct sqlvar_struct *var;

	var = c->daInput.sqlvar;
	for (i = 0; i < c->daInput.sqld; i++, var++) {
		data = argv[i];

		switch(TYPE(data)) {
		case T_NIL:
			var->sqltype = CSTRINGTYPE;
			var->sqldata = NULL;
			var->sqllen = 0;
			*var->sqlind = -1;
			break;
		case T_FIXNUM:
			var->sqldata = (char *)ALLOC(long);
			*((long *)var->sqldata) = FIX2LONG(data);
			var->sqltype = CLONGTYPE;
			var->sqllen = sizeof(long);
			*var->sqlind = 0;
			break;
		case T_FLOAT:
			var->sqldata = (char *)ALLOC(double);
			*((double *)var->sqldata) = NUM2DBL(data);
			var->sqltype = CDOUBLETYPE;
			var->sqllen = sizeof(double);
			*var->sqlind = 0;
			break;
		case T_TRUE:
		case T_FALSE:
			var->sqldata = ALLOC(char);
			*var->sqldata = TYPE(data) == T_TRUE? 't': 'f';
			var->sqltype = CCHARTYPE;
			var->sqllen = sizeof(char);
			*var->sqlind = 0;
			break;
		default:
			klass = rb_obj_class(data);
			if (klass == rb_cTime) {
				char buffer[30];
				short year, month, day, hour, minute, second;
				int usec;
				mint ret;
				dtime_t *dt;

				year = FIX2INT(rb_funcall(data, s_year, 0));
				month = FIX2INT(rb_funcall(data, s_month, 0));
				day = FIX2INT(rb_funcall(data, s_day, 0));
				hour = FIX2INT(rb_funcall(data, s_hour, 0));
				minute = FIX2INT(rb_funcall(data, s_min, 0));
				second = FIX2INT(rb_funcall(data, s_sec, 0));
				usec = FIX2INT(rb_funcall(data, s_usec, 0));

				dt = ALLOC(dtime_t);

				dt->dt_qual = TU_DTENCODE(TU_YEAR, TU_F5);
				snprintf(buffer, sizeof(buffer), "%d-%d-%d %d:%d:%d.%d",
					year, month, day, hour, minute, second, usec/10);
				ret = dtcvasc(buffer, dt);
				if (ret < 0)
					rb_raise(rb_eOperationalError,
						"Unable to convert '%s' to DATETIME [Error %d]",
						RSTRING_PTR(data), ret);

				var->sqldata = (char *)dt;
				var->sqltype = CDTIMETYPE;
				var->sqllen = sizeof(dtime_t);
				*var->sqlind = 0;
				break;
			}
			if (klass == rb_cSlob) {
				slob_t *slob;

				Data_Get_Struct(data, slob_t, slob);

				var->sqldata = (char *)ALLOC(ifx_lo_t);
				memcpy(var->sqldata, &slob->lo, sizeof(slob->lo));
				var->sqltype = SQLUDTFIXED;
				var->sqlxid = slob->type;
				var->sqllen = sizeof(ifx_lo_t);
				*var->sqlind = 0;
				break;
			}
			if (rb_respond_to(data, s_read)) {
				char *str;
				loc_t *loc;
				long len;

				data = rb_funcall(data, s_read, 0);
				str = RSTRING_PTR(data);
				len = RSTRING_LEN(data);

				loc = (loc_t *)ALLOC(loc_t);
				byfill((char *)loc, sizeof(loc_t), 0);
				loc->loc_loctype = LOCMEMORY;
				loc->loc_buffer = (char *)ALLOC_N(char, len);
				memcpy(loc->loc_buffer, str, len);
				loc->loc_bufsize = loc->loc_size = len;

				var->sqldata = (char *)loc;
				var->sqltype = CLOCATORTYPE;
				var->sqllen = sizeof(loc_t);
				*var->sqlind = 0;
				break;
			}
			{
			VALUE str;
			str = rb_check_string_type(data);
			if (NIL_P(str)) {
				data = rb_obj_as_string(data);
			}
			else {
				data = str;
			}
			}
		case T_STRING: {
			char *str;
			long len;

			str = RSTRING_PTR(data);
			len = RSTRING_LEN(data);
			var->sqldata = ALLOC_N(char, len + 1);
			memcpy(var->sqldata, str, len);
			var->sqldata[len] = 0;
			var->sqltype = CSTRINGTYPE;
			var->sqllen = len;
			*var->sqlind = 0;
			break;
		}
		}
	}
}

/*
 * Returns an array or a hash  of Ruby objects containing the record fetched.
 */
static VALUE
make_result(cursor_t *c, VALUE record)
{
	VALUE item;
	register int i;
	register struct sqlvar_struct *var;

	var = c->daOutput->sqlvar;
	for (i = 0; i < c->daOutput->sqld; i++, var++) {
		if (*var->sqlind == -1) {
			item = Qnil;
		} else {
		switch(var->sqltype) {
		case SQLCHAR:
		case SQLVCHAR:
		case SQLNCHAR:
		case SQLNVCHAR:
			item = rb_str_new2(var->sqldata);
			break;
		case SQLSMINT:
			item = INT2FIX(*(int2 *)var->sqldata);
			break;
		case SQLINT:
		case SQLSERIAL:
			item = INT2NUM(*(int4 *)var->sqldata);
			break;
		case SQLINT8:
		case SQLSERIAL8:
			INT82NUM((ifx_int8_t *)var->sqldata, item);
			break;
		case SQLSMFLOAT:
			item = rb_float_new(*(float *)var->sqldata);
			break;
		case SQLFLOAT:
			item = rb_float_new(*(double *)var->sqldata);
			break;
		case SQLDATE: {
			VALUE year, month, day;
			int2 mdy[3];

			rjulmdy(*(int4 *)var->sqldata, mdy);
			year = INT2FIX(mdy[2]);
			month = INT2FIX(mdy[0]);
			day = INT2FIX(mdy[1]);
			item = rb_funcall(rb_cDate, s_new, 3, year, month, day);
			break;
		}
		case SQLDTIME: {
			register short qual, i;
			short year, month, day, hour, minute, second;
			int usec;
			dtime_t dt;
			register char *dgts;

			month = day = 1;
			year = hour = minute = second = usec = 0;
			dt.dt_qual = TU_DTENCODE(TU_YEAR, TU_F5);
			dtextend((dtime_t *)var->sqldata, &dt);
			dgts = dt.dt_dec.dec_dgts;

			for (i = 0, qual = TU_YEAR;
				 qual <= TU_F5 && i < dt.dt_dec.dec_ndgts; qual++) {
				switch(qual) {
				case TU_YEAR:
					year = 100*dgts[i++];
					year += dgts[i++];
					break;
				case TU_MONTH:
					month = dgts[i++];
					break;
				case TU_DAY:
					day = dgts[i++];
					break;
				case TU_HOUR:
					hour = dgts[i++];
					break;
				case TU_MINUTE:
					minute = dgts[i++];
					break;
				case TU_SECOND:
					second = dgts[i++];
					break;
				case TU_F1:
					usec = 10000*dgts[i++];
					break;
				case TU_F3:
					usec += 100*dgts[i++];
					break;
				case TU_F5:
					usec += dgts[i++];
					break;
				}
			}

			item = rb_funcall(rb_cTime, s_utc, 7,
				INT2FIX(year), INT2FIX(month), INT2FIX(day),
				INT2FIX(hour), INT2FIX(minute), INT2FIX(second),
				INT2FIX(usec));

			break;
		}
		case SQLINTERVAL: {
			VALUE constructor, value;
			intrvl_t *data, invl;
			short sign;

			data = (intrvl_t *)var->sqldata;
			if (TU_START(data->in_qual) <= TU_MONTH) {
				invl.in_qual = TU_IENCODE(9, TU_YEAR, TU_MONTH);
				constructor = s_from_months;
			}
			else {
				invl.in_qual = TU_IENCODE(9, TU_DAY, TU_F5);
				constructor = s_from_seconds;
			}

			invextend(data, &invl);
			sign = invl.in_dec.dec_pos == 0? -1 : 1;

			if (TU_START(data->in_qual) <= TU_MONTH) {
				int i, exp, months;
				long years;
				char *dgts;

				exp = invl.in_dec.dec_exp;
				dgts = invl.in_dec.dec_dgts;
				months = years = 0;

				for(i = 0; i < invl.in_dec.dec_ndgts; i++, exp--) {
					if (exp > 5)
						years = years*100 + dgts[i];
					else
						months += dgts[i];
				}
				for(i = exp - 5; i > 0; i--)
					years *= 100;
				value = LONG2NUM(sign*years);
				value = rb_funcall(value, s_mul, 1, INT2FIX(12));
				value = rb_funcall(value, s_add, 1, INT2FIX(sign*months));
			}
			else {
				int i, exp, usec;
				long days, seconds;
				char *dgts;

				exp = invl.in_dec.dec_exp;
				dgts = invl.in_dec.dec_dgts;
				days = seconds = usec = 0;

				for(i = 0; i < invl.in_dec.dec_ndgts; i++, exp--) {
					if(exp > 3)
						days = days*100 + dgts[i];
					else if (exp == 3)
						seconds += dgts[i]*60*60;
					else if (exp == 2)
						seconds += dgts[i]*60;
					else if (exp == 1)
						seconds += dgts[i];
					else if (exp == 0)
						usec += dgts[i]*10000;
					else if (exp == -1)
						usec += dgts[i]*100;
					else if (exp == -2)
						usec += dgts[i];
				}

				for(i = exp - 3; i > 0; i--)
					days *= 100;

				value = LONG2FIX(days);
				value = rb_funcall(value, s_mul, 1, LONG2FIX(sign*24*60*60));
				value = rb_funcall(value, s_add, 1, LONG2FIX(sign*seconds));

				if (usec != 0) {
					VALUE argv[2] = { INT2FIX(sign*usec), LONG2FIX(1000000L) };
					VALUE frac = rb_class_new_instance(2, argv, rb_cRational);
					value = rb_funcall(frac, s_add, 1, value);
				}
			}

			item = rb_funcall(rb_mInterval, constructor, 1, value);
			break;
		}
		case SQLDECIMAL:
		case SQLMONEY: {
			char buffer[40];
			mint ret;

			ret = dectoasc((dec_t *)var->sqldata, buffer,
					sizeof(buffer) - 1, -1);
			if (ret < 0)
				rb_raise(rb_eOperationalError,
					"Unable to convert DECIMAL to BigDecimal [Error %d]", ret);

			buffer[sizeof(buffer) - 1] = 0;
			item = rb_funcall(rb_cBigDecimal, s_new, 1, rb_str_new2(buffer));
			break;
		}
		case SQLBOOL:
			item = var->sqldata[0]? Qtrue: Qfalse;
			break;
		case SQLBYTES:
		case SQLTEXT: {
			loc_t *loc;
			loc = (loc_t *)var->sqldata;
			item = rb_str_new(loc->loc_buffer, loc->loc_size);
			break;
		}
		case SQLUDTFIXED:
			if (ISSMARTBLOB(var->sqltype, var->sqlxid)) {
				slob_t *slob;

				item = slob_alloc(rb_cSlob);
				Data_Get_Struct(item, slob_t, slob);
				memcpy(&slob->lo, var->sqldata, sizeof(ifx_lo_t));
				slob->type = var->sqlxid;
				slob->database_id = c->database_id;
				slob->db = c->db;
				break;
			}
		case SQLSET:
		case SQLMULTISET:
		case SQLLIST:
		case SQLROW:
		case SQLCOLLECTION:
		case SQLROWREF:
		case SQLUDTVAR:
		case SQLREFSER8:
		case SQLLVARCHAR:
		case SQLSENDRECV:
		case SQLIMPEXP:
		case SQLIMPEXPBIN:
		case SQLUNKNOWN:
		default:
			item = Qnil;
			break;
		}
		}
		if (BUILTIN_TYPE(record) == T_ARRAY) {
			rb_ary_store(record, i, item);
		}
        else {
			rb_hash_aset(record, RARRAY(c->field_names)->ptr[i], item);
		}
	}
	return record;
}

/* class Database --------------------------------------------------------- */

static void
database_free(void *p)
{
	EXEC SQL begin declare section;
		char *did;
	EXEC SQL end   declare section;

	did = p;
	EXEC SQL disconnect :did;
	xfree(p);
}

static VALUE
database_alloc(VALUE klass)
{
	char *did;

	did = ALLOC_N(char, IDSIZE<<1);
	did[0] = did[IDSIZE] = 0;
	return Data_Wrap_Struct(klass, 0, database_free, did);
}

/* :nodoc: */
static VALUE
rb_database_initialize(int argc, VALUE *argv, VALUE self)
{
	VALUE arg[3];

	EXEC SQL begin declare section;
		char *dbname, *user = NULL, *pass = NULL, *did;
	EXEC SQL end   declare section;

	rb_scan_args(argc, argv, "12", &arg[0], &arg[1], &arg[2]);

	if (NIL_P(arg[0]))
		rb_raise(rb_eProgrammingError, "A database name must be specified");

	Data_Get_Struct(self, char, did);

	dbname  = StringValueCStr(arg[0]);
	snprintf(did, IDSIZE, "DB%lX", self);

	if (!NIL_P(arg[1]))
		user = StringValueCStr(arg[1]);

	if (!NIL_P(arg[2]))
		pass = StringValueCStr(arg[2]);

	if (user && pass)
		EXEC SQL connect to :dbname as :did user :user
			using :pass with concurrent transaction;
	else
		EXEC SQL connect to :dbname as :did with concurrent transaction;

	if (SQLCODE < 0)
		raise_ifx_extended();

	return self;
}

/*
 * call-seq:
 * db.close  => db
 *
 * Disconnects <i>db</i> and returns __self__
 */
static VALUE
rb_database_close(VALUE self)
{
	EXEC SQL begin declare section;
		char *did;
	EXEC SQL end   declare section;

	Data_Get_Struct(self, char, did);
	did += IDSIZE;
	if (*did)
		EXEC SQL free :did;
	did -= IDSIZE;
	EXEC SQL disconnect :did;

	return self;
}

/*
 * call-seq:
 * db.immediate(query)  => fixnum
 * db.execute(query)    => fixnum
 *
 * Executes <i>query</i> and returns the number of rows affected.
 * <i>query</i> must not return rows. Executes efficiently any
 * non-parameterized or DQL statement.
 */

static VALUE
rb_database_immediate(VALUE self, VALUE arg)
{
	EXEC SQL begin declare section;
		char *query, *did;
	EXEC SQL end   declare section;

	Data_Get_Struct(self, char, did);

	EXEC SQL set connection :did;
	if (SQLCODE < 0)
		raise_ifx_extended();

	query = StringValueCStr(arg);
	EXEC SQL execute immediate :query;
	if (SQLCODE < 0)
		raise_ifx_extended();

	return INT2FIX(sqlca.sqlerrd[2]);
}

/*
 * call-seq:
 * db.rollback  => db
 *
 * Rolls back a transaction and returns __self__.
 */
static VALUE
rb_database_rollback(VALUE self)
{
	EXEC SQL begin declare section;
		char *did;
	EXEC SQL end   declare section;

	Data_Get_Struct(self, char, did);

	EXEC SQL set connection :did;
	if (SQLCODE < 0)
		raise_ifx_extended();

	EXEC SQL rollback;
	return self;
}

/*
 * call-seq:
 * db.commit  => db
 *
 * Commits a transaction and returns __self__.
 */
static VALUE
rb_database_commit(VALUE self)
{
	EXEC SQL begin declare section;
		char *did;
	EXEC SQL end   declare section;

	Data_Get_Struct(self, char, did);

	EXEC SQL set connection :did;
	if (SQLCODE < 0)
		raise_ifx_extended();

	EXEC SQL commit;
	return self;
}

static VALUE
database_transfail(VALUE self)
{
	rb_database_rollback(self);
	return Qundef;
}

/*
 * call-seq:
 * db.transaction {|db| block }  => db
 *
 * Opens a transaction and executes <i>block</i>, passing __self__ as parameter.
 * If an exception is raised, the transaction is rolled back. It is commited
 * otherwise.
 *
 * Returns __self__.
 */
static VALUE
rb_database_transaction(VALUE self)
{
	VALUE ret;
	EXEC SQL begin declare section;
		char *did;
	EXEC SQL end   declare section;

	Data_Get_Struct(self, char, did);

	EXEC SQL set connection :did;
	if (SQLCODE < 0)
		raise_ifx_extended();

	EXEC SQL commit;

	EXEC SQL begin work;
	ret = rb_rescue(rb_yield, self, database_transfail, self);
	if (ret == Qundef)
		rb_raise(rb_eOperationalError, "Transaction rolled back");
	EXEC SQL commit;
	return self;
}

/*
 * call-seq:
 * db.columns(tablename)  => array
 *
 * Returns an array with information for every column of the given table.
 */
static VALUE
rb_database_columns(VALUE self, VALUE tablename)
{
	VALUE v, column, result;
	char *stype;
	static char *stypes[] = {
		"CHAR", "SMALLINT", "INTEGER", "FLOAT", "SMALLFLOAT", "DECIMAL",
		"SERIAL", "DATE", "MONEY", "NULL", "DATETIME", "BYTE",
		"TEXT", "VARCHAR", "INTERVAL", "NCHAR", "NVARCHAR", "INT8",
		"SERIAL8", "SET", "MULTISET", "LIST", "UNNAMED ROW", "NAMED ROW",
		"VARIABLE-LENGTH OPAQUE TYPE"
	};

	static char *qualifiers[] = {
		"YEAR", "MONTH", "DAY", "HOUR", "MINUTE", "SECOND"
	};

	EXEC SQL begin declare section;
		char *did, *cid;
		char *tabname;
		int tabid, xid;
		varchar colname[129];
		short coltype, collength;
		char deftype[2];
		varchar defvalue[257];
	EXEC SQL end   declare section;

	Data_Get_Struct(self, char, did);

	EXEC SQL set connection :did;
	if (SQLCODE < 0)
		raise_ifx_extended();

	tabname = StringValueCStr(tablename);

	EXEC SQL select tabid into :tabid from systables where tabname = :tabname;

	if (SQLCODE == SQLNOTFOUND)
		rb_raise(rb_eProgrammingError, "Table '%s' doesn't exist", tabname);

	result = rb_ary_new();

	cid = did + IDSIZE;

	if (!*cid) {
		EXEC SQL begin declare section;
			char sid[IDSIZE];
		EXEC SQL end   declare section;

		snprintf(sid, IDSIZE, "COLS%lX", self);
		snprintf(cid, IDSIZE, "COLC%lX", self);

		EXEC SQL prepare :sid from
			'select colname, coltype, collength, extended_id,
				type, default, c.colno
			from syscolumns c, outer sysdefaults d
			where c.tabid = ? and c.tabid = d.tabid
				and c.colno = d.colno
			order by c.colno';
		EXEC SQL declare :cid cursor for :sid;
		if (SQLCODE < 0) {
			cid[0] = 0;
			raise_ifx_extended();
		}
	}

	EXEC SQL open :cid using :tabid;
	if (SQLCODE < 0)
		raise_ifx_extended();

	for(;;) {
		EXEC SQL fetch :cid into :colname, :coltype, :collength, :xid,
			:deftype, :defvalue;
		if (SQLCODE < 0)
			raise_ifx_extended();

		if (SQLCODE == SQLNOTFOUND)
			break;

		column = rb_hash_new();
		rb_hash_aset(column, sym_name, rb_str_new2(colname));
		rb_hash_aset(column, sym_type, INT2FIX(coltype));
		rb_hash_aset(column, sym_nullable, coltype&0x100? Qfalse: Qtrue);
		rb_hash_aset(column, sym_xid, INT2FIX(xid));

		if ((coltype&0xFF) < 23) {
			stype = coltype == 4118? stypes[23]: stypes[coltype&0xFF];
		}
		else {
			stype = stypes[24];
		}
		rb_hash_aset(column, sym_stype, rb_str_new2(stype));
		rb_hash_aset(column, sym_length, INT2FIX(collength));

		switch(coltype&0xFF) {
		case SQLVCHAR:
		case SQLNVCHAR:
		case SQLMONEY:
		case SQLDECIMAL:
			rb_hash_aset(column, sym_precision, INT2FIX(collength >> 8));
			rb_hash_aset(column, sym_scale, INT2FIX(collength&0xFF));
			break;
		case SQLDATE:
		case SQLDTIME:
		case SQLINTERVAL:
			rb_hash_aset(column, sym_length, INT2FIX(collength >> 8));
			rb_hash_aset(column, sym_precision, INT2FIX((collength&0xF0) >> 4));
			rb_hash_aset(column, sym_scale, INT2FIX(collength&0xF));
			break;
		default:
			rb_hash_aset(column, sym_precision, INT2FIX(0));
			rb_hash_aset(column, sym_scale, INT2FIX(0));
		}

		if (!deftype[0]) {
			v = Qnil;
		}
		else {
			switch(deftype[0]) {
			case 'C': {
				char current[28];
				snprintf(current, sizeof(current), "CURRENT %s TO %s",
					qualifiers[(collength&0xF0) >> 5],
					qualifiers[(collength&0xF)>>1]);
				v = rb_str_new2(current);
				break;
			}
			case 'L':
				switch (coltype & 0xFF) {
				case SQLCHAR:
				case SQLNCHAR:
				case SQLVCHAR:
				case SQLNVCHAR:
					v = rb_str_new2(defvalue);
					break;
				default: {
					char *s = defvalue;
					while(*s++ != ' ');
					if ((coltype&0xFF) == SQLFLOAT ||
						(coltype&0xFF) == SQLSMFLOAT ||
						(coltype&0xFF) == SQLMONEY ||
						(coltype&0xFF) == SQLDECIMAL)
						v = rb_float_new(atof(s));
					else
						v = LONG2FIX(atol(s));
				}
				}
				break;
			case 'N':
				v = rb_str_new2("NULL");
				break;
			case 'T':
				v = rb_str_new2("today");
				break;
			case 'U':
				v = rb_str_new2("user");
				break;
			case 'S':
			default: /* XXX */
				v = Qnil;
			}
		}
		rb_hash_aset(column, sym_default, v);
		rb_ary_push(result, column);
	}

	EXEC SQL close :cid;

	return result;
}

/* class Statement ------------------------------------------------------- */

static void
statement_mark(cursor_t *c)
{
	rb_gc_mark(c->db);
	if (c->array)
		rb_gc_mark(c->array);
	if (c->hash)
		rb_gc_mark(c->hash);
	if (c->field_names)
		rb_gc_mark(c->field_names);
}

static void
statement_free(void *p)
{
	EXEC SQL begin declare section;
		char *sid, *did;
	EXEC SQL end   declare section;

	free_input_slots(p);
	free_output_slots(p);

	did = ((cursor_t *)p)->database_id;
	EXEC SQL set connection :did;
	if (SQLCODE >= 0) {
		sid = ((cursor_t *)p)->stmt_id;
		EXEC SQL free :sid;
	}

	xfree(p);
}

static VALUE
statement_alloc(VALUE klass)
{
	cursor_t *c;

	c = ALLOC(cursor_t);
	memset(c, 0, sizeof(cursor_t));
	return Data_Wrap_Struct(klass, statement_mark, statement_free, c);
}

/* :nodoc: */
static VALUE
statement_initialize(VALUE self, VALUE db, VALUE query)
{
	struct sqlda *output;
	cursor_t *c;
	EXEC SQL begin declare section;
		char *c_query, *sid, *did;
	EXEC SQL end   declare section;

	Data_Get_Struct(db, char, did);
	EXEC SQL set connection :did;
	if (SQLCODE < 0)
		raise_ifx_extended();

	Data_Get_Struct(self, cursor_t, c);
	c->db = db;
	c->database_id = did;
	output = c->daOutput;
	snprintf(c->stmt_id, sizeof(c->stmt_id), "STMT%lX", self);
	sid = c->stmt_id;
	c_query = StringValueCStr(query);

	EXEC SQL prepare :sid from :c_query;
	if (SQLCODE < 0)
		raise_ifx_extended();

	alloc_input_slots(c, c_query);
	EXEC SQL describe :sid into output;
	c->daOutput = output;

	c->is_select = (SQLCODE == 0 || SQLCODE == SQ_EXECPROC);

	if (c->is_select)
		alloc_output_slots(c);
	else {
		xfree(c->daOutput);
		c->daOutput = NULL;
	}

	return self;
}

static VALUE statement_drop(VALUE);
/*
 * call-seq:
 * Statement.new(database, query)                 => statement
 * Statement.new(database, query) {|stmt| block } => obj
 *
 * Creates a <code>Statement</code> object based on <i>query</i> in the
 * context of <i>database</i>.
 * In the first form the <code>Statement</code> object is returned.
 * In the second form the Statement object is passed to the block and when it
 * terminates, the Statement object is dropped, returning the value of the
 * block.
 *
 * <i>query</i> may contain '?' placeholders for input parameters;
 * it must not be a query returning more than one row
 * (use <code>Cursor</code> instead.)
 */
static VALUE
statement_s_new(int argc, VALUE *argv, VALUE klass)
{
	VALUE stmt;

	stmt = rb_class_new_instance(argc, argv, klass);

	if (rb_block_given_p())
		return rb_ensure(rb_yield, stmt, statement_drop, stmt);

	return stmt;
}

/*
 * call-seq:
 * stmt[*params]  => fixnum or hash
 *
 * Executes the previously prepared statement, binding <i>params</i> as
 * input parameters.
 *
 * Returns the record retrieved, in the case of a singleton select, or the
 * number of rows affected, in the case of any other statement.
 */
static VALUE
statement_call(int argc, VALUE *argv, VALUE self)
{
	struct sqlda *input, *output;
	cursor_t *c;
	EXEC SQL begin declare section;
		char *sid, *did;
	EXEC SQL end   declare section;

	Data_Get_Struct(self, cursor_t, c);

	did = c->database_id;
	EXEC SQL set connection :did;
	if (SQLCODE < 0)
		raise_ifx_extended();

	output = c->daOutput;
	input = &c->daInput;
	sid = c->stmt_id;

	if (argc != input->sqld)
		rb_raise(rb_eArgError, "wrong number of arguments (%d for %d)",
			argc, input->sqld);

	if (c->is_select) {
		if (argc) {
			bind_input_params(c, argv);
			EXEC SQL execute :sid into descriptor output
				using descriptor input;
			clean_input_slots(c);
		}
		else
			EXEC SQL execute :sid into descriptor output;

		if (SQLCODE < 0)
			raise_ifx_extended();

		if (SQLCODE == SQLNOTFOUND)
			return Qnil;
		return make_result(c, rb_hash_new());
	}
	else {
		if (argc)  {
			bind_input_params(c, argv);
			EXEC SQL execute :sid using descriptor input;
			clean_input_slots(c);
		}
		else
			EXEC SQL execute :sid;
	}
	if (SQLCODE < 0)
		raise_ifx_extended();

	return INT2FIX(sqlca.sqlerrd[2]);
}

/*
 * call-seq:
 * stmt.drop
 *
 * Frees the statement and the memory associated with it.
 */
static VALUE
statement_drop(VALUE self)
{
	cursor_t *c;
	EXEC SQL begin declare section;
		char *sid, *did;
	EXEC SQL end   declare section;

	Data_Get_Struct(self, cursor_t, c);
	free_input_slots(c);
	free_output_slots(c);

	did = c->database_id;
	EXEC SQL set connection :did;
	if (SQLCODE < 0)
		return Qnil;
	sid = c->stmt_id;
	EXEC SQL free :sid;

	return Qnil;
}

/* module SequentialCursor ----------------------------------------------- */

/* Decides whether to use an Array or a Hash, and instantiate a new
 * object or reuse an existing one.
 */
#define RECORD(c, type, bang, record) \
do {\
	if (type == T_ARRAY) {\
		if (bang) {\
			if (!c->array)\
				c->array = rb_ary_new2(c->daOutput->sqld);\
			record = c->array;\
		}\
		else\
			record = rb_ary_new2(c->daOutput->sqld);\
	}\
	else {\
		if (bang) {\
			if (!c->hash)\
				c->hash = rb_hash_new();\
			record = c->hash;\
		}\
		else\
			record = rb_hash_new();\
	}\
}while(0)

/*
 * Base function for fetch* methods, except *_many
 */
static VALUE
fetch(VALUE self, VALUE type, int bang)
{
	EXEC SQL begin declare section;
		char *cid, *did;
	EXEC SQL end   declare section;
	cursor_t *c;
	struct sqlda *output;
	VALUE record;

	Data_Get_Struct(self, cursor_t, c);
	if (!c->is_open)
		rb_raise(rb_eProgrammingError, "Open the cursor object first");

	did = c->database_id;
	EXEC SQL set connection :did;
	if (SQLCODE < 0)
		raise_ifx_extended();

	output = c->daOutput;
	cid = c->cursor_id;

	EXEC SQL fetch :cid using descriptor output;
	if (SQLCODE < 0)
		raise_ifx_extended();

	if (SQLCODE == SQLNOTFOUND)
		return Qnil;

	RECORD(c, type, bang, record);
	return make_result(c, record);
}

/*
 * call-seq:
 * cursor.fetch  => array or nil
 *
 * Fetches the next record.
 *
 * Returns the record fetched as an array, or nil if there are no
 * records left.
 */
static VALUE
seqcur_fetch(VALUE self)
{
	return fetch(self, T_ARRAY, 0);
}

/*
 * call-seq:
 * cursor.fetch!  => array or nil
 *
 * Fetches the next record, storing it in the same Array object every time
 * it is called.
 * 
 * Returns the record fetched as an array, or nil if there are no
 * records left.
 */
static VALUE
seqcur_fetch_bang(VALUE self)
{
	return fetch(self, T_ARRAY, 1);
}

/*
 * call-seq:
 * cursor.fetch_hash  => hash or nil
 *
 * Fetches the next record.
 *
 * Returns the record fetched as a hash, or nil if there are no
 * records left.
 */
static VALUE
seqcur_fetch_hash(VALUE self)
{
	return fetch(self, T_HASH, 0);
}

/*
 * call-seq:
 * cursor.fetch_hash!  => hash or nil
 *
 * Fetches the next record, storing it in the same Hash object every time
 * it is called.
 * 
 * Returns the record fetched as a hash, or nil if there are no
 * records left.
 */
static VALUE
seqcur_fetch_hash_bang(VALUE self)
{
	return fetch(self, T_HASH, 1);
}

/*
 * Base function for fetch*_many, fetch*_all and each_by methods
 */
static VALUE
fetch_many(VALUE self, VALUE n, VALUE type)
{
	EXEC SQL begin declare section;
		char *cid, *did;
	EXEC SQL end   declare section;
	cursor_t *c;
	struct sqlda *output;
	VALUE record, records;
	register long i, max;
	register int all = n == Qnil;

	Data_Get_Struct(self, cursor_t, c);
	if (!c->is_open)
		rb_raise(rb_eProgrammingError, "Open the cursor object first");

	did = c->database_id;
	EXEC SQL set connection :did;
	if (SQLCODE < 0)
		raise_ifx_extended();

	output = c->daOutput;
	cid = c->cursor_id;

	if (!all) {
		max = FIX2LONG(n);
		records = rb_ary_new2(max);
	}
	else {
		records = rb_ary_new();
	}

	for(i = 0; all || i < max; i++) {
		EXEC SQL fetch :cid using descriptor output;
		if (SQLCODE < 0)
			raise_ifx_extended();

		if (SQLCODE == SQLNOTFOUND)
			break;

		if (type == T_ARRAY)
			record = rb_ary_new2(c->daOutput->sqld);
		else
			record = rb_hash_new();
		rb_ary_store(records, i, make_result(c, record));
	}

	return records;
}

/*
 * call-seq:
 * cursor.fetch_many(n)  => array
 *
 * Reads at most <i>n</i> records.
 *
 * Returns the records read as an array of arrays
 */
static VALUE
seqcur_fetch_many(VALUE self, VALUE n)
{
	return fetch_many(self, n, T_ARRAY);
}

/*
 * call-seq:
 * cursor.fetch_hash_many(n)  => array
 *
 * Reads at most <i>n</i> records.
 * Returns the records read as an array of hashes.
 */
static VALUE
seqcur_fetch_hash_many(VALUE self, VALUE n)
{
	return fetch_many(self, n, T_HASH);
}

/*
 * call-seq:
 * cursor.fetch_all  => array
 *
 * Returns all the records left as an array of arrays
 */
static VALUE
seqcur_fetch_all(VALUE self)
{
	return fetch_many(self, Qnil, T_ARRAY);
}

/*
 * call-seq:
 * cursor.fetch_hash_all  => array
 *
 * Returns all the records left as an array of hashes
 */
static VALUE
seqcur_fetch_hash_all(VALUE self)
{
	return fetch_many(self, Qnil, T_HASH);
}

/*
 * Base function for each* methods, except each*_by
 */
static VALUE
each(VALUE self, VALUE type, int bang)
{
	cursor_t *c;
	EXEC SQL begin declare section;
		char *cid, *did;
	EXEC SQL end   declare section;
	struct sqlda *output;
	VALUE record;

	Data_Get_Struct(self, cursor_t, c);
	if (!c->is_open)
		rb_raise(rb_eProgrammingError, "Open the cursor object first");

	did = c->database_id;
	EXEC SQL set connection :did;
	if (SQLCODE < 0)
		raise_ifx_extended();

	output = c->daOutput;
	cid = c->cursor_id;

	for(;;) {
		EXEC SQL fetch :cid using descriptor output;
		if (SQLCODE < 0)
			raise_ifx_extended();

		if (SQLCODE == SQLNOTFOUND)
			return self;
		RECORD(c, type, bang, record);
		rb_yield(make_result(c, record));
	}
}

/*
 * Base function for each*_by methods
 */
static VALUE
each_by(VALUE self, VALUE n, VALUE type)
{
	VALUE records;

	for(;;) {
		records = fetch_many(self, n, type);
		if (RARRAY(records)->len == 0)
			return self;
		rb_yield(records);
	}
}

/*
 * call-seq:
 * cursor.each {|record| block } => cursor
 *
 * Iterates over the remaining records, passing each <i>record</i> to the
 * <i>block</i> as an array.
 *
 * Returns __self__.
 */
static VALUE
seqcur_each(VALUE self)
{
	return each(self, T_ARRAY, 0);
}

/*
 * call-seq:
 * cursor.each! {|record| block } => cursor
 *
 * Iterates over the remaining records, passing each <i>record</i> to the
 * <i>block</i> as an array. No new Array objects are created for each record.
 * The same Array object is reused in each call.
 *
 * Returns __self__.
 */
static VALUE
seqcur_each_bang(VALUE self)
{
	return each(self, T_ARRAY, 1);
}

/*
 * call-seq:
 * cursor.each_hash {|record| block } => cursor
 *
 * Iterates over the remaining records, passing each <i>record</i> to the
 * <i>block</i> as a hash.
 *
 * Returns __self__.
 */
static VALUE
seqcur_each_hash(VALUE self)
{
	return each(self, T_HASH, 0);
}

/*
 * call-seq:
 * cursor.each_hash! {|record| block } => cursor
 *
 * Iterates over the remaining records, passing each <i>record</i> to the
 * <i>block</i> as a hash. No new Hash objects are created for each record.
 * The same Hash object is reused in each call.
 *
 * Returns __self__.
 */
static VALUE
seqcur_each_hash_bang(VALUE self)
{
	return each(self, T_HASH, 1);
}

/*
 * call-seq:
 * cursor.each_by(n) {|records| block } => cursor
 *
 * Iterates over the remaining records, passing at most <i>n</i> <i>records</i>
 * to the <i>block</i> as arrays.
 *
 * Returns __self__.
 */
static VALUE
seqcur_each_by(VALUE self, VALUE n)
{
	return each_by(self, n, T_ARRAY);
}

/*
 * call-seq:
 * cursor.each_hash_by(n) {|records| block } => cursor
 *
 * Iterates over the remaining records, passing at most <i>n</i> <i>records</i>
 * to the <i>block</i> as hashes.
 *
 * Returns __self__.
 */
static VALUE
seqcur_each_hash_by(VALUE self, VALUE n)
{
	return each_by(self, n, T_HASH);
}

/* module InsertCursor --------------------------------------------------- */

/*
 * call-seq:
 * cursor.put(*params)
 *
 * Binds <i>params</i> as input parameters and executes the insert statement.
 * The records are not written immediatly to disk, unless the insert buffer
 * is full, the <code>flush</code> method is called, the cursor is closed or
 * the transaction is commited.
 */
static VALUE
inscur_put(int argc, VALUE *argv, VALUE self)
{
	struct sqlda *input;
	cursor_t *c;
	EXEC SQL begin declare section;
		char *cid, *did;
	EXEC SQL end   declare section;

	Data_Get_Struct(self, cursor_t, c);
	if (!c->is_open)
		rb_raise(rb_eProgrammingError, "Open the cursor object first");

	did = c->database_id;
	EXEC SQL set connection :did;
	if (SQLCODE < 0)
		raise_ifx_extended();

	input = &c->daInput;
	cid = c->cursor_id;

	bind_input_params(c, argv);
	if (argc != input->sqld)
		rb_raise(rb_eArgError, "wrong number of arguments (%d for %d)",
			argc, input->sqld);

	EXEC SQL put :cid using descriptor input;
	clean_input_slots(c);
	if (SQLCODE < 0)
		raise_ifx_extended();

	/* XXX 2-448, Guide to SQL: Sytax*/
	return INT2FIX(sqlca.sqlerrd[2]);
}

/*
 * call-seq:
 * cursor.flush => cursor
 *
 * Flushes the insert buffer, writing data to disk.
 *
 * Returns __self__.
 */
static VALUE
inscur_flush(VALUE self)
{
	cursor_t *c;
	EXEC SQL begin declare section;
		char *cid, *did;
	EXEC SQL end   declare section;

	Data_Get_Struct(self, cursor_t, c);
	if (!c->is_open)
		rb_raise(rb_eProgrammingError, "Open the cursor object first");

	did = c->database_id;
	EXEC SQL set connection :did;
	if (SQLCODE < 0)
		raise_ifx_extended();

	cid = c->cursor_id;
	EXEC SQL flush :cid;
	return self;
}

/* module ScrollCursor --------------------------------------------------- */

/*
 * Provides the Array-like functionality for scroll cursors when using the
 * cursor[index] syntax
 */
static VALUE
scrollcur_entry(VALUE self, VALUE index, VALUE type, int bang)
{
	cursor_t *c;
	struct sqlda *output;
	VALUE record;
	EXEC SQL begin declare section;
		char *cid, *did;
		long pos;
	EXEC SQL end   declare section;

	Data_Get_Struct(self, cursor_t, c);
	if (!c->is_open)
		rb_raise(rb_eProgrammingError, "Open the cursor object first");

	did = c->database_id;
	EXEC SQL set connection :did;
	if (SQLCODE < 0)
		return Qnil;

	output = c->daOutput;
	cid = c->cursor_id;

	if (NIL_P(index))
		EXEC SQL fetch current :cid using descriptor output;
	else if ((pos = NUM2LONG(index) + 1) > 0)
		EXEC SQL fetch absolute :pos :cid using descriptor output;
	else {
		EXEC SQL fetch last :cid;
		EXEC SQL fetch relative :pos :cid using descriptor output;
	}

	if (SQLCODE == SQLNOTFOUND)
		return Qnil;

	if (SQLCODE < 0)
		raise_ifx_extended();

	RECORD(c, type, bang, record);
	return make_result(c, record);
}

/*
 * Provides the Array-like functionality for scroll cursors when using the
 * cursor[start, length] syntax
 */
static VALUE
scrollcur_subseq(VALUE self, VALUE start, VALUE length, VALUE type)
{
	VALUE first, records;
	EXEC SQL begin declare section;
		long pos;
	EXEC SQL end   declare section;

	first = scrollcur_entry(self, start, type, 0);
	if (NIL_P(first))
		return Qnil;

	pos = NUM2LONG(length) - 1;

	if (pos > 0) {
		length = LONG2NUM(pos);
		records = fetch_many(self, length, type);
	}
	else
		records = rb_ary_new();

	rb_ary_unshift(records, first);

	return records;
}

/*
 * Base function for slice and slice_hash methods
 */
static VALUE
slice(int argc, VALUE *argv, VALUE self, VALUE type)
{
	if (argc == 2) {
		if (NUM2LONG(argv[1]) <= 0)
			rb_raise(rb_eArgError, "length must be positive");
		return scrollcur_subseq(self, argv[0], argv[1], type);
	}
	if (argc != 1)
		rb_scan_args(argc, argv, "11", 0, 0);

	return scrollcur_entry(self, argv[0], type, 0);
}

/*
 * call-seq:
 *    cursor[index]  => array or nil
 *    cursor[start, length]  => array or nil
 *    cursor.slice(index)  => array or nil
 *    cursor.slice(start, length)  => array or nil
 *
 * Returns the record at _index_, or returns a subarray starting at _start_
 * and continuing for _length_ records. Negative indices count backward from
 * the end of the cursor (-1 is the last element). Returns nil if the
 * (starting) index is out of range.
 *
 * <b>Warning</b>: if the (starting) index is negative and out of range, the
 * position in the cursor is set to the last record. Otherwise the current
 * position in the cursor is preserved.
 */
static VALUE
scrollcur_slice(int argc, VALUE *argv, VALUE self)
{
	return slice(argc, argv, self, T_ARRAY);
}

/*
 * call-seq:
 * cursor.slice!(index)  => array or nil
 *
 * Returns the record at _index_. Negative indices count backward from
 * the end of the cursor (-1 is the last element). Returns nil if the index
 * is out of range.
 *
 * Stores the record fetched always in the same Array object.
 *
 * <b>Warning</b>: if the index is negative and out of range, the
 * position in the cursor is set to the last record. Otherwise the current
 * position in the cursor is preserved.
 */
static VALUE
scrollcur_slice_bang(VALUE self, VALUE index)
{
	return scrollcur_entry(self, index, T_ARRAY, 1);
}

/*
 * call-seq:
 *    cursor.slice_hash(index)  => hash or nil
 *    cursor.slice_hash(start, length)  => array or nil
 *
 * Returns the record at _index_, or returns a subarray starting at _start_
 * and continuing for _length_ records. Negative indices count backward from
 * the end of the cursor (-1 is the last element). Returns nil if the
 * (starting) index is out of range.
 *
 * <b>Warning</b>: if the (starting) index is negative and out of range, the
 * position in the cursor is set to the last record. Otherwise the current
 * position in the cursor is preserved.
 */
static VALUE
scrollcur_slice_hash(int argc, VALUE *argv, VALUE self)
{
	return slice(argc, argv, self, T_HASH);
}

/*
 * call-seq:
 * cursor.slice_hash!(index)  => hash or nil
 *
 * Returns the record at _index_. Negative indices count backward from
 * the end of the cursor (-1 is the last element). Returns nil if the index
 * is out of range.
 *
 * Stores the record fetched always in the same Hash object.
 *
 * <b>Warning</b>: if the index is negative and out of range, the
 * position in the cursor is set to the last record. Otherwise the current
 * position in the cursor is preserved.
 */
static VALUE
scrollcur_slice_hash_bang(VALUE self, VALUE index)
{
	return scrollcur_entry(self, index, T_HASH, 1);
}

/*
 * Base function for prev* and next* methods
 */
static VALUE
scrollcur_rel(int argc, VALUE *argv, VALUE self, int dir, VALUE type, int bang)
{
	cursor_t *c;
	struct sqlda *output;
	VALUE offset, record;
	EXEC SQL begin declare section;
		char *cid, *did;
		long pos;
	EXEC SQL end   declare section;

	Data_Get_Struct(self, cursor_t, c);
	if (!c->is_open)
		rb_raise(rb_eProgrammingError, "Open the cursor object first");

	did = c->database_id;
	EXEC SQL set connection :did;
	if (SQLCODE < 0)
		return Qnil;

	rb_scan_args(argc, argv, "01", &offset);
	pos = dir*(NIL_P(offset)? 1: NUM2LONG(offset));

	output = c->daOutput;
	cid = c->cursor_id;
	EXEC SQL fetch relative :pos :cid using descriptor output;

	if (SQLCODE == SQLNOTFOUND)
		return Qnil;

	if (SQLCODE < 0)
		raise_ifx_extended();

	RECORD(c, type, bang, record);
	return make_result(c, record);
}

/* call-seq:
 * cursor.prev(offset = 1)  => array or nil
 *
 * Returns the previous _offset_ th record. Negative indices count
 * forward from the current position. Returns nil if the _offset_ is out of
 * range.
 */
static VALUE
scrollcur_prev(int argc, VALUE *argv, VALUE self)
{
	return scrollcur_rel(argc, argv, self, -1, T_ARRAY, 0);
}

/* call-seq:
 * cursor.prev!(offset = 1)  => array or nil
 *
 * Returns the previous _offset_ th record. Negative indices count
 * forward from the current position. Returns nil if the _offset_ is out of
 * range.
 *
 * Stores the record fetched always in the same Array object.
 */
static VALUE
scrollcur_prev_bang(int argc, VALUE *argv, VALUE self)
{
	return scrollcur_rel(argc, argv, self, -1, T_ARRAY, 1);
}

/* call-seq:
 * cursor.prev_hash(offset = 1)  => hash or nil
 *
 * Returns the previous _offset_ th record. Negative indices count
 * forward from the current position. Returns nil if the _offset_ is out of
 * range.
 */
static VALUE
scrollcur_prev_hash(int argc, VALUE *argv, VALUE self)
{
	return scrollcur_rel(argc, argv, self, -1, T_HASH, 0);
}

/* call-seq:
 * cursor.prev_hash!(offset = 1)  => hash or nil
 *
 * Returns the previous _offset_ th record. Negative indices count
 * forward from the current position. Returns nil if the _offset_ is out of
 * range.
 *
 * Stores the record fetched always in the same Hash object.
 */
static VALUE
scrollcur_prev_hash_bang(int argc, VALUE *argv, VALUE self)
{
	return scrollcur_rel(argc, argv, self, -1, T_HASH, 1);
}

/* call-seq:
 * cursor.next(offset = 1)  => array or nil
 *
 * Returns the next _offset_ th record. Negative indices count
 * backward from the current position. Returns nil if the _offset_ is out of
 * range.
 */
static VALUE
scrollcur_next(int argc, VALUE *argv, VALUE self)
{
	return scrollcur_rel(argc, argv, self, 1, T_ARRAY, 0);
}

/* call-seq:
 * cursor.next!(offset = 1)  => array or nil
 *
 * Returns the next _offset_ th record. Negative indices count
 * backward from the current position. Returns nil if the _offset_ is out of
 * range.
 *
 * Stores the record fetched always in the same Array object.
 */
static VALUE
scrollcur_next_bang(int argc, VALUE *argv, VALUE self)
{
	return scrollcur_rel(argc, argv, self, 1, T_ARRAY, 1);
}

/* call-seq:
 * cursor.next_hash(offset = 1)  => hash or nil
 *
 * Returns the next _offset_ th record. Negative indices count
 * backward from the current position. Returns nil if the _offset_ is out of
 * range.
 */
static VALUE
scrollcur_next_hash(int argc, VALUE *argv, VALUE self)
{
	return scrollcur_rel(argc, argv, self, 1, T_HASH, 0);
}

/* call-seq:
 * cursor.next_hash!(offset = 1)  => hash or nil
 *
 * Returns the next _offset_ th record. Negative indices count
 * backward from the current position. Returns nil if the _offset_ is out of
 * range.
 *
 * Stores the record fetched always in the same Hash object.
 */
static VALUE
scrollcur_next_hash_bang(int argc, VALUE *argv, VALUE self)
{
	return scrollcur_rel(argc, argv, self, 1, T_HASH, 1);
}

/*
 * call-seq:
 * cursor.first  => array or nil
 *
 * Returns the first record of the cursor. If the cursor is empty,
 * returns nil.
 */
static VALUE
scrollcur_first(VALUE self)
{
	return scrollcur_entry(self, INT2FIX(0), T_ARRAY, 0);
}

/*
 * call-seq:
 * cursor.first!  => array or nil
 *
 * Returns the first record of the cursor. If the cursor is empty,
 * returns nil.
 *
 * Stores the record fetched always in the same Array object.
 */
static VALUE
scrollcur_first_bang(VALUE self)
{
	return scrollcur_entry(self, INT2FIX(0), T_ARRAY, 1);
}

/*
 * call-seq:
 * cursor.first_hash  => hash or nil
 *
 * Returns the first record of the cursor. If the cursor is empty,
 * returns nil.
 */
static VALUE
scrollcur_first_hash(VALUE self)
{
	return scrollcur_entry(self, INT2FIX(0), T_HASH, 0);
}

/*
 * call-seq:
 * cursor.first_hash!  => hash or nil
 *
 * Returns the first record of the cursor. If the cursor is empty,
 * returns nil.
 *
 * Stores the record fetched always in the same Hash object.
 */
static VALUE
scrollcur_first_hash_bang(VALUE self)
{
	return scrollcur_entry(self, INT2FIX(0), T_HASH, 1);
}

/*
 * call-seq:
 * cursor.last  => array or nil
 *
 * Returns the last record of the cursor. If the cursor is empty,
 * returns nil.
 */
static VALUE
scrollcur_last(VALUE self)
{
	return scrollcur_entry(self, INT2FIX(-1), T_ARRAY, 0);
}

/*
 * call-seq:
 * cursor.last!  => array or nil
 *
 * Returns the last record of the cursor. If the cursor is empty,
 * returns nil.
 *
 * Stores the record fetched always in the same Array object.
 */
static VALUE
scrollcur_last_bang(VALUE self)
{
	return scrollcur_entry(self, INT2FIX(-1), T_ARRAY, 1);
}

/*
 * call-seq:
 * cursor.last_hash  => hash or nil
 *
 * Returns the last record of the cursor. If the cursor is empty,
 * returns nil.
 */
static VALUE
scrollcur_last_hash(VALUE self)
{
	return scrollcur_entry(self, INT2FIX(-1), T_HASH, 0);
}

/*
 * call-seq:
 * cursor.last_hash!  => hash or nil
 *
 * Returns the last record of the cursor. If the cursor is empty,
 * returns nil.
 *
 * Stores the record fetched always in the same Hash object.
 */
static VALUE
scrollcur_last_hash_bang(VALUE self)
{
	return scrollcur_entry(self, INT2FIX(-1), T_HASH, 1);
}

/*
 * call-seq:
 * cursor.current  => array or nil
 *
 * Returns the current record of the cursor. If the cursor is empty,
 * returns nil.
 */
static VALUE
scrollcur_current(VALUE self)
{
	return scrollcur_entry(self, Qnil, T_ARRAY, 0);
}

/*
 * call-seq:
 * cursor.current!  => array or nil
 *
 * Returns the current record of the cursor. If the cursor is empty,
 * returns nil.
 *
 * Stores the record fetched always in the same Array object.
 */
static VALUE
scrollcur_current_bang(VALUE self)
{
	return scrollcur_entry(self, Qnil, T_ARRAY, 1);
}

/*
 * call-seq:
 * cursor.current_hash  => hash or nil
 *
 * Returns the current record of the cursor. If the cursor is empty,
 * returns nil.
 */
static VALUE
scrollcur_current_hash(VALUE self)
{
	return scrollcur_entry(self, Qnil, T_HASH, 0);
}

/*
 * call-seq:
 * cursor.current_hash!  => hash or nil
 *
 * Returns the current record of the cursor. If the cursor is empty,
 * returns nil.
 *
 * Stores the record fetched always in the same Hash object.
 */
static VALUE
scrollcur_current_hash_bang(VALUE self)
{
	return scrollcur_entry(self, Qnil, T_HASH, 1);
}

/* class Cursor ---------------------------------------------------------- */
static void
cursor_close_or_free(cursor_t *c, short op)
{
	EXEC SQL begin declare section;
		char *cid, *sid, *did;
	EXEC SQL end   declare section;

	if (op == 1 && !c->is_open)
		return;

	c->is_open = 0;
	if (op == 1)
		clean_input_slots(c);
	else {
		free_input_slots(c);
		free_output_slots(c);
	}

	did = c->database_id;
	EXEC SQL set connection :did;
	if (SQLCODE < 0)
		return;

	cid = c->cursor_id;
	EXEC SQL close :cid;

	if (op == 2) {
		sid = c->stmt_id;
		EXEC SQL free :cid; EXEC SQL free :sid;
	}
}

static void
cursor_mark(cursor_t *c)
{
	rb_gc_mark(c->db);
	if (c->array)
		rb_gc_mark(c->array);
	if (c->hash)
		rb_gc_mark(c->hash);
	if (c->field_names)
		rb_gc_mark(c->field_names);
}

static void
cursor_free(void *p)
{
	cursor_close_or_free(p, 2);
	xfree(p);
}

static VALUE
cursor_alloc(VALUE klass)
{
	cursor_t *c;

	c = ALLOC(cursor_t);
	memset(c, 0, sizeof(cursor_t));
	return Data_Wrap_Struct(klass, cursor_mark, cursor_free, c);
}

/* :nodoc: */
static VALUE
cursor_initialize(int argc, VALUE *argv, VALUE self)
{
	VALUE db, query, options;
	VALUE scroll, hold;
	struct sqlda *output;
	cursor_t *c;
	EXEC SQL begin declare section;
		char *c_query;
		char *cid, *sid, *did;
	EXEC SQL end   declare section;

	rb_scan_args(argc, argv, "21", &db, &query, &options);
	Data_Get_Struct(db, char, did);

	EXEC SQL set connection :did;
	if (SQLCODE < 0)
		raise_ifx_extended();

	Data_Get_Struct(self, cursor_t, c);
	c->db = db;
	c->database_id = did;
	scroll = hold = Qfalse;
	snprintf(c->cursor_id, sizeof(c->cursor_id), "CUR%lX", self);
	snprintf(c->stmt_id, sizeof(c->stmt_id), "STMT%lX", self);
	cid = c->cursor_id; sid = c->stmt_id;
	c_query = StringValueCStr(query);

	if (!NIL_P(options)) {
		Check_Type(options, T_HASH);
		scroll = rb_hash_aref(options, sym_scroll);
		hold = rb_hash_aref(options, sym_hold);
	}

	EXEC SQL prepare :sid from :c_query;
	if (SQLCODE < 0)
		raise_ifx_extended();

	if (RTEST(scroll) && RTEST(hold))
		EXEC SQL declare :cid scroll cursor with hold for :sid;
	else if (RTEST(hold))
		EXEC SQL declare :cid cursor with hold for :sid;
	else if (RTEST(scroll))
		EXEC SQL declare :cid scroll cursor for :sid;
	else
		EXEC SQL declare :cid cursor for :sid;

	if (SQLCODE < 0)
		raise_ifx_extended();

	alloc_input_slots(c, c_query);
	EXEC SQL describe :sid into output;
	c->daOutput = output;

	c->is_select = (SQLCODE == 0 || SQLCODE == SQ_EXECPROC);

	if (c->is_select) {
		alloc_output_slots(c);
		rb_extend_object(self, rb_mSequentialCursor);
		if (scroll)
			rb_extend_object(self, rb_mScrollCursor);
	}
	else {
		xfree(c->daOutput);
		c->daOutput = NULL;
		rb_extend_object(self, rb_mInsertCursor);
	}
	return self;
}

static VALUE cursor_drop(VALUE self);
/*
 * call-seq:
 * Cursor.new(database, query, options)                    => cursor
 * Cursor.new(database, query, options) {|cursor| block }  => obj
 *
 * Creates a Cursor object based on <i>query</i> using <i>options</i>
 * in the context of <i>database</i> but does not open it.
 * In the first form the Cursor object is returned.
 * In the second form the Cursor object is passed to the block and when it
 * terminates, the Cursor object is dropped, returning the value of the block.
 * 
 * <i>options</i> can be nil or a Hash object with the following possible keys:
 * 
 *   :scroll => true or false
 *   :hold   => true or false
 */
static VALUE
rb_cursor_s_new(int argc, VALUE *argv, VALUE klass)
{
	VALUE cursor;

	cursor = rb_class_new_instance(argc, argv, klass);

	if (rb_block_given_p())
		return rb_ensure(rb_yield, cursor, cursor_drop, cursor);

	return cursor;
}

/*
 * call-seq:
 * cursor.id  => string
 *
 * Returns the cursor ID
 */
static VALUE
cursor_id(VALUE self)
{
	cursor_t *c;

	Data_Get_Struct(self, cursor_t, c);
	return rb_str_new2(c->cursor_id);
}

/*
 * call-seq:
 * cursor.open(*params)  => cursor
 *
 * Executes the previously prepared select statement, binding <i>params</i> as
 * input parameters.
 *
 * Returns __self__.
 */
static VALUE
cursor_open(int argc, VALUE *argv, VALUE self)
{
	struct sqlda *input;
	cursor_t *c;
	EXEC SQL begin declare section;
		char *cid, *did;
	EXEC SQL end   declare section;

	Data_Get_Struct(self, cursor_t, c);

	if (c->is_open)
		return self;

	did = c->database_id;
	EXEC SQL set connection :did;
	if (SQLCODE < 0)
		raise_ifx_extended();

	input = &c->daInput;
	cid = c->cursor_id;

	if (c->is_select) {
		if (argc != input->sqld) {
			rb_raise(rb_eArgError, "wrong number of arguments (%d for %d)",
				argc, input->sqld);
		}
		if (argc) {
			bind_input_params(c, argv);
			EXEC SQL open :cid using descriptor input
				with reoptimization;
			clean_input_slots(c);
		}
		else
			EXEC SQL open :cid with reoptimization;
	}
	else
		EXEC SQL open :cid;

	if (SQLCODE < 0)
		raise_ifx_extended();

	c->is_open = 1;
	return self;
}

/*
 * call-seq:
 * cursor.close  => cursor
 *
 * Closes the cursor and returns __self__.
 */
static VALUE
cursor_close(VALUE self)
{
	cursor_t *c;

	Data_Get_Struct(self, cursor_t, c);
	cursor_close_or_free(c, 1);
	return self;
}

/*
 * call-seq:
 * cursor.drop => nil
 *
 * Closes the cursor and frees the memory associated with it. The cursor
 * cannot be opened again.
 */
static VALUE
cursor_drop(VALUE self)
{
	cursor_t *c;

	Data_Get_Struct(self, cursor_t, c);
	cursor_close_or_free(c, 2);

	return Qnil;
}

/* Entry point ------------------------------------------------------------ */

void Init_informixc(void)
{
	/* module Informix ---------------------------------------------------- */
	rb_mInformix = rb_define_module("Informix");
	rb_mScrollCursor = rb_define_module_under(rb_mInformix, "ScrollCursor");
	rb_mInsertCursor = rb_define_module_under(rb_mInformix, "InsertCursor");

	/* class Slob --------------------------------------------------------- */
	rb_cSlob = rb_define_class_under(rb_mInformix, "Slob", rb_cObject);
	rb_define_alloc_func(rb_cSlob, slob_alloc);
	rb_define_method(rb_cSlob, "initialize", rb_slob_initialize, -1);
	rb_define_singleton_method(rb_cSlob, "new", rb_slob_s_new, -1);
	rb_define_method(rb_cSlob, "open", rb_slob_open, -1);
	rb_define_method(rb_cSlob, "close", rb_slob_close, 0);
	rb_define_method(rb_cSlob, "read", rb_slob_read, 1);
	rb_define_method(rb_cSlob, "write", rb_slob_write, 1);
	rb_define_method(rb_cSlob, "seek", rb_slob_seek, 2);
	rb_define_method(rb_cSlob, "tell", rb_slob_tell, 0);
	rb_define_alias(rb_cSlob, "pos", "tell");
	rb_define_method(rb_cSlob, "pos=", rb_slob_set_pos, 1);
	rb_define_method(rb_cSlob, "truncate", rb_slob_truncate, 1);
	rb_define_method(rb_cSlob, "stat", rb_slob_stat, 0);
	rb_define_method(rb_cSlob, "<<", rb_slob_addstr, 1);
	rb_define_method(rb_cSlob, "rewind", rb_slob_rewind, 0);
	rb_define_method(rb_cSlob, "lock", rb_slob_lock, 4);
	rb_define_method(rb_cSlob, "unlock", rb_slob_unlock, 3);

	rb_define_method(rb_cSlob, "atime", rb_slob_atime, 0);
	rb_define_method(rb_cSlob, "ctime", rb_slob_ctime, 0);
	rb_define_method(rb_cSlob, "mtime", rb_slob_mtime, 0);
	rb_define_method(rb_cSlob, "refcnt", rb_slob_refcnt, 0);
	rb_define_method(rb_cSlob, "size", rb_slob_size, 0);

	rb_define_method(rb_cSlob, "estbytes", rb_slob_estbytes, 0);
	rb_define_method(rb_cSlob, "extsz", rb_slob_extsz, 0);
	rb_define_method(rb_cSlob, "flags", rb_slob_flags, 0);
	rb_define_method(rb_cSlob, "maxbytes", rb_slob_maxbytes, 0);
	rb_define_method(rb_cSlob, "sbspace", rb_slob_sbspace, 0);

	rb_define_method(rb_cSlob, "extsz=", rb_slob_set_extsz, 1);
	rb_define_method(rb_cSlob, "flags=", rb_slob_set_flags, 1);

	rb_define_const(rb_cSlob, "CLOB", INT2FIX(XID_CLOB));
	rb_define_const(rb_cSlob, "BLOB", INT2FIX(XID_BLOB));

	#define DEF_SLOB_CONST(k) rb_define_const(rb_cSlob, #k, INT2FIX(LO_##k))

	/* Access modes */
	DEF_SLOB_CONST(RDONLY);
	DEF_SLOB_CONST(DIRTY_READ);
	DEF_SLOB_CONST(WRONLY);
	DEF_SLOB_CONST(APPEND);
	DEF_SLOB_CONST(RDWR);
	DEF_SLOB_CONST(BUFFER);
	DEF_SLOB_CONST(NOBUFFER);
	DEF_SLOB_CONST(LOCKALL);
	DEF_SLOB_CONST(LOCKRANGE);
	DEF_SLOB_CONST(SEEK_SET);
	DEF_SLOB_CONST(SEEK_CUR);
	DEF_SLOB_CONST(SEEK_END);

	/* Creation-time flags */
	DEF_SLOB_CONST(LOG);
	DEF_SLOB_CONST(NOLOG);
	DEF_SLOB_CONST(KEEP_LASTACCESS_TIME);
	DEF_SLOB_CONST(NOKEEP_LASTACCESS_TIME);

	/* Ranges */
	DEF_SLOB_CONST(CURRENT_END);
	DEF_SLOB_CONST(MAX_END);

	/* Lock modes */
	DEF_SLOB_CONST(SHARED_MODE);
	DEF_SLOB_CONST(EXCLUSIVE_MODE);

	/* class Slob::Stat --------------------------------------------------- */

	rb_cSlobStat = rb_define_class_under(rb_cSlob, "Stat", rb_cObject);
	rb_define_alloc_func(rb_cSlobStat, slobstat_alloc);
	rb_define_method(rb_cSlobStat, "initialize", rb_slobstat_initialize, 1);

	rb_include_module(rb_cSlobStat, rb_mComparable);
	rb_define_method(rb_cSlobStat, "<=>", rb_slobstat_cmp, 1);

	rb_define_method(rb_cSlobStat, "atime", rb_slobstat_atime, 0);
	rb_define_method(rb_cSlobStat, "ctime", rb_slobstat_ctime, 0);
	rb_define_method(rb_cSlobStat, "mtime", rb_slobstat_mtime, 0);
	rb_define_method(rb_cSlobStat, "refcnt", rb_slobstat_refcnt, 0);
	rb_define_method(rb_cSlobStat, "size", rb_slobstat_size, 0);

	/* class Database ----------------------------------------------------- */
	rb_cDatabase = rb_define_class_under(rb_mInformix, "Database", rb_cObject);
	rb_define_alloc_func(rb_cDatabase, database_alloc);
	rb_define_method(rb_cDatabase, "initialize", rb_database_initialize, -1);
	rb_define_method(rb_cDatabase, "close", rb_database_close, 0);
	rb_define_alias(rb_cDatabase, "disconnect", "close");
	rb_define_method(rb_cDatabase, "immediate", rb_database_immediate, 1);
	rb_define_alias(rb_cDatabase, "do", "immediate");
	rb_define_alias(rb_cDatabase, "execute", "immediate");
	rb_define_method(rb_cDatabase, "rollback", rb_database_rollback, 0);
	rb_define_method(rb_cDatabase, "commit", rb_database_commit, 0);
	rb_define_method(rb_cDatabase, "transaction", rb_database_transaction, 0);
	rb_define_method(rb_cDatabase, "columns", rb_database_columns, 1);

	/* class Statement ---------------------------------------------------- */
	rb_cStatement = rb_define_class_under(rb_mInformix, "Statement", rb_cObject);
	rb_define_alloc_func(rb_cStatement, statement_alloc);
	rb_define_method(rb_cStatement, "initialize", statement_initialize, 2);
	rb_define_singleton_method(rb_cStatement, "new", statement_s_new, -1);
	rb_define_method(rb_cStatement, "[]", statement_call, -1);
	rb_define_alias(rb_cStatement, "call", "[]");
	rb_define_alias(rb_cStatement, "execute", "[]");
	rb_define_method(rb_cStatement, "drop", statement_drop, 0);

	/* module SequentialCursor -------------------------------------------- */
	rb_mSequentialCursor = rb_define_module_under(rb_mInformix, "SequentialCursor");
	rb_define_method(rb_mSequentialCursor, "fetch", seqcur_fetch, 0);
	rb_define_method(rb_mSequentialCursor, "fetch!", seqcur_fetch_bang, 0);
	rb_define_method(rb_mSequentialCursor, "fetch_hash", seqcur_fetch_hash, 0);
	rb_define_method(rb_mSequentialCursor, "fetch_hash!", seqcur_fetch_hash_bang, 0);
	rb_define_method(rb_mSequentialCursor, "fetch_many", seqcur_fetch_many, 1);
	rb_define_method(rb_mSequentialCursor, "fetch_hash_many", seqcur_fetch_hash_many, 1);
	rb_define_method(rb_mSequentialCursor, "fetch_all", seqcur_fetch_all, 0);
	rb_define_method(rb_mSequentialCursor, "fetch_hash_all", seqcur_fetch_hash_all, 0);
	rb_define_method(rb_mSequentialCursor, "each", seqcur_each, 0);
	rb_define_method(rb_mSequentialCursor, "each!", seqcur_each_bang, 0);
	rb_define_method(rb_mSequentialCursor, "each_hash", seqcur_each_hash, 0);
	rb_define_method(rb_mSequentialCursor, "each_hash!", seqcur_each_hash_bang, 0);
	rb_define_method(rb_mSequentialCursor, "each_by", seqcur_each_by, 1);
	rb_define_method(rb_mSequentialCursor, "each_hash_by", seqcur_each_hash_by, 1);

	/* InsertCursor ------------------------------------------------------- */
	rb_define_method(rb_mInsertCursor, "put", inscur_put, -1);
	rb_define_method(rb_mInsertCursor, "flush", inscur_flush, 0);

	/* ScrollCursor ------------------------------------------------------- */
	rb_define_method(rb_mScrollCursor, "[]", scrollcur_slice, -1);
	rb_define_alias(rb_mScrollCursor, "slice", "[]");
	rb_define_method(rb_mScrollCursor, "slice!", scrollcur_slice_bang, 1);
	rb_define_method(rb_mScrollCursor, "slice_hash", scrollcur_slice_hash, -1);
	rb_define_method(rb_mScrollCursor, "slice_hash!", scrollcur_slice_hash_bang, 1);
	rb_define_method(rb_mScrollCursor, "prev", scrollcur_prev, -1);
	rb_define_method(rb_mScrollCursor, "prev!", scrollcur_prev_bang, -1);
	rb_define_method(rb_mScrollCursor, "prev_hash", scrollcur_prev_hash, -1);
	rb_define_method(rb_mScrollCursor, "prev_hash!", scrollcur_prev_hash_bang, -1);
	rb_define_method(rb_mScrollCursor, "next", scrollcur_next, -1);
	rb_define_method(rb_mScrollCursor, "next!", scrollcur_next_bang, -1);
	rb_define_method(rb_mScrollCursor, "next_hash", scrollcur_next_hash, -1);
	rb_define_method(rb_mScrollCursor, "next_hash!", scrollcur_next_hash_bang, -1);
	rb_define_method(rb_mScrollCursor, "first", scrollcur_first, 0);
	rb_define_method(rb_mScrollCursor, "first!", scrollcur_first_bang, 0);
	rb_define_method(rb_mScrollCursor, "first_hash", scrollcur_first_hash, 0);
	rb_define_method(rb_mScrollCursor, "first_hash!", scrollcur_first_hash_bang, 0);
	rb_define_method(rb_mScrollCursor, "last", scrollcur_last, 0);
	rb_define_method(rb_mScrollCursor, "last!", scrollcur_last_bang, 0);
	rb_define_method(rb_mScrollCursor, "last_hash", scrollcur_last_hash, 0);
	rb_define_method(rb_mScrollCursor, "last_hash!", scrollcur_last_hash_bang, 0);
	rb_define_method(rb_mScrollCursor, "current", scrollcur_current, 0);
	rb_define_method(rb_mScrollCursor, "current!", scrollcur_current_bang, 0);
	rb_define_method(rb_mScrollCursor, "current_hash", scrollcur_current_hash, 0);
	rb_define_method(rb_mScrollCursor, "current_hash!", scrollcur_current_hash_bang, 0);

	/* class Cursor ------------------------------------------------------- */
	rb_cCursor = rb_define_class_under(rb_mInformix, "Cursor", rb_cObject);
	rb_define_alloc_func(rb_cCursor, cursor_alloc);
	rb_define_method(rb_cCursor, "initialize", cursor_initialize, -1);
	rb_define_singleton_method(rb_cCursor, "new", rb_cursor_s_new, -1);
	rb_define_method(rb_cCursor, "id", cursor_id, 0);
	rb_define_method(rb_cCursor, "open", cursor_open, -1);
	rb_define_method(rb_cCursor, "close", cursor_close, 0);
	rb_define_method(rb_cCursor, "drop", cursor_drop, 0);

	/* Global constants --------------------------------------------------- */
	rb_require("date");
	rb_cDate = rb_const_get(rb_cObject, rb_intern("Date"));

	rb_require("bigdecimal");
	rb_cBigDecimal = rb_const_get(rb_cObject, rb_intern("BigDecimal"));

	rb_cRational = rb_const_get(rb_cObject, rb_intern("Rational"));

	rb_require("ifx_except");
	rb_eError = rb_const_get(rb_mInformix, rb_intern("Error"));
	rb_eWarning = rb_const_get(rb_mInformix, rb_intern("Warning"));
	rb_eInternalError = rb_const_get(rb_mInformix, rb_intern("InternalError"));
	rb_eProgrammingError = rb_const_get(rb_mInformix, rb_intern("ProgrammingError"));
	rb_eOperationalError = rb_const_get(rb_mInformix, rb_intern("OperationalError"));
	rb_eDatabaseError = rb_const_get(rb_mInformix, rb_intern("DatabaseError"));

	rb_require("ifx_interval");
	rb_mInterval = rb_const_get(rb_mInformix, rb_intern("Interval"));

	/* Global symbols ----------------------------------------------------- */
	#define INTERN(sym) s_##sym = rb_intern(#sym)
	INTERN(read); INTERN(new);
	INTERN(utc);  INTERN(day); INTERN(month); INTERN(year);
	INTERN(hour); INTERN(min); INTERN(sec); INTERN(usec);
	INTERN(to_s); INTERN(to_i);
	INTERN(add_info);
	INTERN(qual); INTERN(from_months); INTERN(from_seconds);
	s_add = rb_intern("+");
	s_mul = rb_intern("*");

	sym_name = ID2SYM(rb_intern("name"));
	sym_type = ID2SYM(rb_intern("type"));
	sym_nullable = ID2SYM(rb_intern("nullable"));
	sym_stype = ID2SYM(rb_intern("stype"));
	sym_length = ID2SYM(rb_intern("length"));
	sym_precision = ID2SYM(rb_intern("precision"));
	sym_scale = ID2SYM(rb_intern("scale"));
	sym_default = ID2SYM(rb_intern("default"));
	sym_xid = ID2SYM(rb_intern("xid"));

	sym_scroll = ID2SYM(rb_intern("scroll"));
	sym_hold = ID2SYM(rb_intern("hold"));

	sym_col_info = ID2SYM(rb_intern("col_info"));
	sym_sbspace = ID2SYM(rb_intern("sbspace"));
	sym_estbytes = ID2SYM(rb_intern("estbytes"));
	sym_extsz = ID2SYM(rb_intern("extsz"));
	sym_createflags = ID2SYM(rb_intern("createflags"));
	sym_openflags = ID2SYM(rb_intern("openflags"));
	sym_maxbytes = ID2SYM(rb_intern("maxbytes"));

	sym_params = ID2SYM(rb_intern("params"));

	sym_YEAR_TO_MONTH = ID2SYM(rb_intern("YEAR_TO_MONTH"));
}
