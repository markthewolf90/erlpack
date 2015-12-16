#coding: utf-8
#cython: embedsignature=True

from cpython cimport *
from libc.stdlib cimport malloc, free
from libc.string cimport *
from libc.limits cimport *
from libc.stdint cimport *
from erlpack.types import Atom

cdef int DEFAULT_RECURSE_LIMIT = 256
cdef size_t max_size = (2 ** 32) - 1;

cdef extern from "encoder.h":
    struct erlpack_buffer:
        char*buf
        size_t length
        size_t allocated_size

    int erlpack_append_int(erlpack_buffer *pk, int d)
    int erlpack_append_nil(erlpack_buffer *pk)
    int erlpack_append_true(erlpack_buffer *pk)
    int erlpack_append_false(erlpack_buffer *pk)
    int erlpack_append_version(erlpack_buffer *pk)
    int erlpack_append_small_integer(erlpack_buffer *pk, unsigned char d)
    int erlpack_append_integer(erlpack_buffer *pk, int32_t d)
    int erlpack_append_unsigned_long_long(erlpack_buffer *pk, unsigned long long d)
    int erlpack_append_long_long(erlpack_buffer *pk, long long d)
    int erlpack_append_double(erlpack_buffer *pk, double f)
    int erlpack_append_atom(erlpack_buffer *pk, PyObject *o)
    int erlpack_append_binary(erlpack_buffer *pk, PyObject *o)
    int erlpack_append_string(erlpack_buffer *pk, PyObject *o)
    int erlpack_append_tuple_header(erlpack_buffer *pk, size_t size)
    int erlpack_append_nil_ext(erlpack_buffer *pk)
    int erlpack_append_list_header(erlpack_buffer *pk, size_t size)
    int erlpack_append_map_header(erlpack_buffer *pk, size_t size)

class EncodingError(Exception):
    pass


cdef class ErlangTermEncoder(object):
    cdef erlpack_buffer pk
    cdef char* _encoding
    cdef char* _unicode_errors
    cdef object _unicode_type
    cdef object _encode_hook

    def __cinit__(self):
        cdef int buf_size = 1024 * 1024
        cdef char*buf = <char*> malloc(buf_size)
        if buf == NULL:
            raise MemoryError('Unable to allocate buffer')

        self.pk.buf = buf
        self.pk.allocated_size = buf_size
        self.pk.length = 0

    def __init__(self, encoding='utf-8', unicode_errors='strict', unicode_type='binary', encode_hook=None):
        cdef object _encoding
        cdef object _unicode_errors

        if encoding is None:
            self._encoding = NULL
            self._unicode_errors = NULL
        else:
            if isinstance(encoding, unicode):
                _encoding = encoding.encode('ascii')
            else:
                _encoding = encoding

            if isinstance(unicode_errors, unicode):
                _unicode_errors = unicode_errors.encode('ascii')
            else:
                _unicode_errors = unicode_errors

            self._encoding = PyString_AsString(_encoding)
            self._unicode_errors = PyString_AsString(_unicode_errors)

        self._unicode_type = unicode_type
        self._encode_hook = encode_hook

    def __dealloc__(self):
        free(self.pk.buf)

    cdef int _pack(self, object o, int nest_limit=DEFAULT_RECURSE_LIMIT) except -1:
        cdef int ret
        cdef long long llval
        cdef unsigned long long ullval
        cdef long longval
        cdef double doubleval
        cdef size_t sizeval
        cdef dict d
        cdef object obj

        if nest_limit < 0:
            raise EncodingError('Exceeded recursion limit')

        if o is None:
            ret = erlpack_append_nil(&self.pk)

        elif o is True:
            ret = erlpack_append_true(&self.pk)

        elif o is False:
            ret = erlpack_append_false(&self.pk)

        elif PyLong_Check(o) or PyInt_Check(o):
            if 0 <= o <= 255:
                ret = erlpack_append_small_integer(&self.pk, <unsigned char> o)

            elif -2147483648 <= o <= 2147483647:
                ret = erlpack_append_integer(&self.pk, <int32_t> o)

            else:
                if o > 0:
                    ullval = o
                    ret = erlpack_append_unsigned_long_long(&self.pk, ullval)
                else:
                    llval = o
                    ret = erlpack_append_long_long(&self.pk, llval)

        elif PyFloat_Check(o):
            doubleval = o
            ret = erlpack_append_double(&self.pk, doubleval)

        elif PyObject_IsInstance(o, Atom):
            ret = erlpack_append_atom(&self.pk, <PyObject *> o)

        elif PyString_Check(o):
            ret = erlpack_append_binary(&self.pk, <PyObject *> o)

        elif PyUnicode_Check(o):
            ret = self._encode_unicode(o)

        elif PyTuple_Check(o):
            sizeval = PyTuple_Size(o)
            if sizeval > max_size:
                raise ValueError('tuple is too large')

            ret = erlpack_append_tuple_header(&self.pk, sizeval)
            if ret != 0:
                return ret

            for item in o:
                ret = self._pack(item, nest_limit - 1)
                if ret != 0:
                    return ret

        elif PyList_Check(o):
            sizeval = PyList_Size(o)
            if sizeval == 0:
                ret = erlpack_append_nil_ext(&self.pk)
            else:

                if sizeval > max_size:
                    raise ValueError("list is too large")

                ret = erlpack_append_list_header(&self.pk, sizeval)
                if ret != 0:
                    return ret

                for item in o:
                    ret = self._pack(item, nest_limit - 1)
                    if ret != 0:
                        return ret

                ret = erlpack_append_nil_ext(&self.pk)

        elif PyDict_CheckExact(o):
            d = <dict> o
            sizeval = PyDict_Size(d)

            if sizeval > max_size:
                raise ValueError("dict is too large")

            ret = erlpack_append_map_header(&self.pk, sizeval)
            if ret != 0:
                return ret

            for k, v in d.iteritems():
                ret = self._pack(k, nest_limit - 1)
                if ret != 0:
                    return ret
                ret = self._pack(v, nest_limit - 1)
                if ret != 0:
                    return ret

        # For user dict types, safer to use .items() # via msgpack-python
        elif PyDict_Check(o):
            sizeval = PyDict_Size(o)
            if sizeval > max_size:
                raise ValueError("dict is too large")

            ret = erlpack_append_map_header(&self.pk, sizeval)
            if ret != 0:
                return ret

            for k, v in o.items():
                ret = self._pack(k, nest_limit - 1)
                if ret != 0:
                    return ret
                ret = self._pack(v, nest_limit - 1)

                if ret != 0:
                    return ret

        elif PyObject_HasAttrString(o, '__erlpack__'):
            obj = o.__erlpack__()
            return self._pack(obj, nest_limit - 1)

        else:
            if self._encode_hook:
                obj = self._encode_hook(o)
                if obj is not None:
                    return self._pack(obj, nest_limit - 1)

            raise NotImplementedError('Unable to serialize %r' % o)

        return ret

    cdef _encode_unicode(self, object obj):
        if not self._encoding:
            return self._pack([ord(x) for x in obj])

        cdef object st = PyUnicode_AsEncodedString(obj, self._encoding, self._unicode_errors)
        cdef size_t size = PyString_Size(st)

        if self._unicode_type == 'binary':
            if size > max_size:
                raise ValueError('unicode string is too large using unicode type binary')

            return erlpack_append_binary(&self.pk, <PyObject*> st)

        elif self._unicode_type == 'str':
            if size > 0xFFF:
                raise ValueError('unicode string is too large using unicode type str')

            return erlpack_append_string(&self.pk, <PyObject*> st)

        else:
            raise TypeError('Unknown unicode encoding type %s' % self._unicode_type)


    cpdef pack(self, object obj):
        cdef int ret
        self.pk.length = 0

        ret = erlpack_append_version(&self.pk)
        if ret == -1:
            raise MemoryError

        ret = self._pack(obj, DEFAULT_RECURSE_LIMIT)
        if ret == -1:
            raise MemoryError
        elif ret:  # should not happen.
            raise TypeError('_pack returned code(%s)' % ret)

        buf = PyBytes_FromStringAndSize(self.pk.buf, self.pk.length)
        self.pk.length = 0
        return buf
