<%
from data_types import dtypes, scalar_cython_type
%>

from bempp.utils cimport Matrix
from bempp.utils.enum_types cimport transposition_mode
from bempp.utils cimport complex_float,complex_double
from cython.operator cimport dereference as deref
from bempp.utils.enum_types cimport TranspositionMode
from bempp.utils.enum_types cimport transposition_mode
cimport bempp.utils.enum_types as enums
from bempp.utils.byte_conversion import convert_to_bytes
from bempp.utils cimport shared_ptr, static_pointer_cast
from bempp.hmat.hmatrix cimport c_HMatrix
from bempp.hmat.block_cluster_tree cimport c_BlockClusterTree
from bempp.hmat.block_cluster_tree cimport BlockClusterTree
from bempp.hmat.block_cluster_tree cimport BlockClusterTreeNode
from bempp.hmat.hmatrix_data cimport HMatrixData
from bempp.hmat.hmatrix_data cimport down_cast_to_low_rank_data
from bempp.hmat.hmatrix_data cimport down_cast_to_dense_data
from bempp.utils.enum_types cimport dense, low_rank_ab

% for pyvalue in dtypes:
from bempp.utils.eigen cimport eigen_matrix_to_np_${pyvalue}
% endfor
from bempp.utils import combined_type
cimport numpy as np
import numpy as np
cimport cython
from libcpp cimport bool


cdef class DiscreteBoundaryOperatorBase:

    property dtype:
        def __get__(self):
            return self._dtype

    property shape:
        def __get__(self):
            raise NotImplementedError("Method not implemented.")

    def as_matrix(self):

        raise NotImplementedError("Method not implemented.")

    def matvec(self,np.ndarray x):

        raise NotImplementedError("Method not implemented.")

    def matmat(self,np.ndarray x):

        return self.matvec(x)

    def __call__(self,np.ndarray x):

        return self.matvec(x)

    def __mul__(self,object x):

        if not isinstance(self,DiscreteBoundaryOperatorBase):
            return x*self

        if isinstance(x,DiscreteBoundaryOperatorBase):
            return _ProductDiscreteBoundaryOperator(self,x)
        elif np.isscalar(x):
            return _ScaledDiscreteBoundaryOperator(self,x)
        else:
            return self.matvec(x)

    def dot(self,object other):
        
        return self.__mul__(other)

    def __add__(self,DiscreteBoundaryOperatorBase other):

        return _SumDiscreteBoundaryOperator(self,other)

    def __neg__(self):

        return _ScaledDiscreteBoundaryOperator(self,-1.0)

    def __sub__(self,DiscreteBoundaryOperatorBase x):
        return self.__add__(-x)
    
    def __repr__(self):
        
        M,N = self.shape
        dt = 'dtype=' + str(self.dtype)
        return '<%text><%dx%d %s with %s></%text>' % (M, N, self.__class__.__name__, dt)

cdef class ZeroDiscreteBoundaryOperator(DiscreteBoundaryOperatorBase):

    cdef object _shape

    def __cinit__(self,int M, int N):
        pass

    def __init__(self,int M, int N):
        self._shape = (M,N)
        self._dtype = np.dtype('float64')
        self.transpose_mode = enums.no_transpose

    property shape:
        def __get__(self):
            if (self.transpose_mode==enums.no_transpose or
                    self.transpose_mode==enums.conjugate):
                return self._shape
            else:
                return (self._shape[1],self._shape[0])

    def as_matrix(self):

        return np.zeros(self.shape,dtype=self.dtype)

    def matvec(self, np.ndarray x):

        cdef bool is_reshaped=False
        if not x.shape[0]==self.shape[1]:
            return ValueError("Wrong dimensions.")

        if x.ndim==1:
            x = x.reshape((-1,1))
            is_reshaped=True

        cdef np.ndarray result = np.zeros((self.shape[0],x.shape[1]),dtype=x.dtype)
        if is_reshaped:
            result = result.ravel()
        return result

    def transpose(self):

        return ZeroDiscreteBoundaryOperator(self.shape[1],self.shape[0])

    def conjugate(self):

        return ZeroDiscreteBoundaryOperator(self.shape[0],self.shape[1])

    def conjugate_transpose(self):

        return self.transpose()




cdef class DiscreteBoundaryOperator(DiscreteBoundaryOperatorBase):

    def __cinit__(self):
        pass

    def __init__(self):
        self.transpose_mode = enums.no_transpose

    def __dealloc__(self):

% for pybasis, cybasis in dtypes.items():
        self._impl_${pybasis}_.reset()
% endfor

    property shape:

        def __get__(self):
            cdef unsigned int rows 
            cdef unsigned int cols

% for pyvalue,cyvalue in dtypes.items():
            if self.dtype=="${pyvalue}":
                rows = deref(self._impl_${pyvalue}_).rowCount()
                cols = deref(self._impl_${pyvalue}_).columnCount()
                if (self.transpose_mode==enums.no_transpose or
                        self.transpose_mode==enums.conjugate):
                    return (rows,cols)
                else:
                    return (cols,rows)
% endfor
            raise ValueError("Unknown value type")
    
    def as_matrix(self):

% for pyvalue in dtypes:

        if self.dtype=="${pyvalue}":
            return self._as_matrix_${pyvalue}()
% endfor

        raise ValueError("Unknown value type")


% for pyvalue,cyvalue in dtypes.items():
    cdef np.ndarray _as_matrix_${pyvalue}(self):

        cdef Matrix[${cyvalue}] mat_data = deref(self._impl_${pyvalue}_).asMatrix()
        if (self.transpose_mode==enums.no_transpose):
            return eigen_matrix_to_np_${pyvalue}(mat_data)
        if (self.transpose_mode==enums.conjugate):
            return np.conjugate(eigen_matrix_to_np_${pyvalue}(mat_data))
        if (self.transpose_mode==enums.transpose):
            return np.transpose(eigen_matrix_to_np_${pyvalue}(mat_data))
        if (self.transpose_mode==enums.conjugate_transpose):
            return np.conjugate(
                    np.transpose(eigen_matrix_to_np_${pyvalue}(mat_data)))


% endfor


    def matvec(self,np.ndarray x):

        if self.dtype=='float64' and np.iscomplexobj(x):
            return self*np.real(x)+1j*(self*np.imag(x))

        cdef np.ndarray x_in
        cdef np.ndarray y_inout

        cdef int rows = self.shape[0]
        cdef int cols = self.shape[1]

        cdef bool is_reshaped = False

        if (x.ndim==1):
            x_in = x.reshape((-1,1),order='F').astype(self.dtype,
                    order='F',casting='safe',copy=False)
            is_reshaped = True
        elif (x.ndim==2):
            x_in = x.astype(self.dtype,order='F',casting='safe',copy=False)
        else:
            raise ValueError('x must have at most two dimensions')

        if (x_in.shape[0]!=self.shape[1]):
            raise ValueError("Wrong dimensions.")

        if self.dtype=='float64':
            y = deref(self._impl_float64_).apply(self.transpose_mode,x_in)
        elif self.dtype=='complex128':
            y = deref(self._impl_complex128_).apply(self.transpose_mode,x_in)
        else:
            raise NotImplementedError("Data type not supported.")

        if is_reshaped:
            y = y.ravel()
        return y

    def _op_with_new_mode(self,mode):

        cdef DiscreteBoundaryOperator res = DiscreteBoundaryOperator()
        res._dtype = self.dtype
        if self.dtype=='float64':
            res._impl_float64_.assign(self._impl_float64_)
        elif self.dtype=='complex128':
            res._impl_complex128_.assign(self._impl_complex128_)
        else:
            raise NotImplementedError("Data type not supported.")
        res.transpose_mode = transposition_mode(mode)
        return res

    def transpose(self):
        return self._op_with_new_mode('transpose')
    
    def conjugate(self):
        return self._op_with_new_mode('conjugate')

    def conjugate_transpose(self):
        return self._op_with_new_mode('conjugate_transpose')

        
cdef class _ScaledDiscreteBoundaryOperator(DiscreteBoundaryOperatorBase):
    cdef DiscreteBoundaryOperatorBase _op
    cdef object _alpha

    def __cinit__(self,DiscreteBoundaryOperatorBase op,object alpha):
        pass

    def __init__(self,DiscreteBoundaryOperatorBase op, object alpha):

        self._op = op
        self._alpha = 1.0*alpha # make sure it is not integer 
        self._dtype = combined_type(np.dtype(type(self._alpha)),op.dtype)

    def as_matrix(self):

        return self._alpha*self._op.as_matrix()

    property shape:

        def __get__(self):
            return self._op.shape

    def matvec(self,np.ndarray x):

        return self._alpha*(self._op*x)

    def transpose(self):

        return _ScaledDiscreteBoundaryOperator(self._op.transpose(),self._alpha)

    def conjugate(self):

        return _ScaledDiscreteBoundaryOperator(self._op.conjugate(),self._alpha)

    def conjugate_transpose(self):

        return _ScaledDiscreteBoundaryOperator(self._op.conjugate_transpose(),self._alpha)

cdef class _SumDiscreteBoundaryOperator(DiscreteBoundaryOperatorBase):

    cdef DiscreteBoundaryOperatorBase _op1
    cdef DiscreteBoundaryOperatorBase _op2

    def __cinit__(self,DiscreteBoundaryOperatorBase op1, DiscreteBoundaryOperatorBase op2):
        pass

    def __init__(self,DiscreteBoundaryOperatorBase op1, DiscreteBoundaryOperatorBase op2):
        if not op1.shape == op2.shape:
            raise ValueError("Both operators must have the same shape")

        self._op1 = op1
        self._op2 = op2

        self._dtype = combined_type(self._op1.dtype,self._op2.dtype)

    property shape:

        def __get__(self):

            return self._op1.shape

    def as_matrix(self):

        return self._op1.as_matrix()+self._op2.as_matrix()

    def matvec(self,np.ndarray x):

        return self._op1*x+self._op2*x

    def transpose(self):

        return _SumDiscreteBoundaryOperator(self._op1.transpose(),self._op2.transpose())

    def conjugate(self):

        return _SumDiscreteBoundaryOperator(self._op1.conjugate(),self._op2.conjugate())

    def conjugate_transpose(self):

        return _SumDiscreteBoundaryOperator(self._op1.conjugate_transpose(),self._op2.conjugate_transpose())

cdef class _ProductDiscreteBoundaryOperator(DiscreteBoundaryOperatorBase):

    cdef DiscreteBoundaryOperatorBase _op1
    cdef DiscreteBoundaryOperatorBase _op2

    def __cinit__(self,DiscreteBoundaryOperatorBase op1, DiscreteBoundaryOperatorBase op2):
        pass

    def __init__(self,DiscreteBoundaryOperatorBase op1, DiscreteBoundaryOperatorBase op2):
        if not op1.shape[1]==op2.shape[0]:
            raise ValueError("Incompatible Dimensions.")

        self._op1 = op1
        self._op2 = op2

        self._dtype = combined_type(self._op1.dtype,self._op2.dtype)

    def as_matrix(self):
        return self._op1.as_matrix()*self._op2.as_matrix()

    def matvec(self,np.ndarray x):

        return self._op1*(self._op2*x)

    property shape:

        def __get__(self):
            return (self._op1.shape[0],self._op2.shape[1])

    def transpose(self):

        return _ProductDiscreteBoundaryOperator(self._op2.transpose(),self._op1.transpose())

    def conjugate(self):

        return _ProductDiscreteBoundaryOperator(self._op1.conjugate(),self._op2.conjugate())

    def conjugate_transpose(self):

        return _ProductDiscreteBoundaryOperator(self._op2.conjugate_transpose(),self._op1.conjugate_transpose())


cdef class SparseDiscreteBoundaryOperator(DiscreteBoundaryOperatorBase):

    def __cinit__(self,op):
        pass

    def __init__(self,op):
        from scipy.sparse import csc_matrix
        self.transpose_mode = enums.no_transpose

        if not isinstance(op,csc_matrix):
            raise ValueError("op must be of type scipy.sparse.csc.csc_matrix")

        self._op = op
        self._dtype = self._op.dtype

    def as_matrix(self):

        return self.spars_operator.to_dense()

    def matvec(self,x):

        return self.sparse_operator*x

    def __add__(self,DiscreteBoundaryOperatorBase other):

        if isinstance(other,SparseDiscreteBoundaryOperator):
            return SparseDiscreteBoundaryOperator(self.sparse_operator+other.sparse_operator)

        else:
            return super(SparseDiscreteBoundaryOperator,self).__add__(other)

    def __mul__(self,object x):

        if not isinstance(self,SparseDiscreteBoundaryOperator):
            return x*self

        if np.isscalar(x):
            return SparseDiscreteBoundaryOperator(x*self.sparse_operator)
        return super(SparseDiscreteBoundaryOperator,self).__mul__(x)

    def __neg__(self):

        return SparseDiscreteBoundaryOperator(-self.sparse_operator)

    def __sub__(self,other):

        if isinstance(other,SparseDiscreteBoundaryOperator):
            return SparseDiscreteBoundaryOperator(self.sparse_operator-other.sparse_operator)

        else:
            return super(SparseDiscreteBoundaryOperator,self).__sub__(other)


    property sparse_operator:
        """ The SciPy sparse matrix representation of the operator """

        def __get__(self):
            if self.transpose_mode==enums.no_transpose:
                return self._op
            if self.transpose_mode==enums.conjugate:
                return self._op.conjugate()
            if self.transpose_mode==enums.conjugate_tranpose:
                return self._op.conjugate().transpose()
            if self.transpose_mode==enums.transpose:
                return self._op.transpose()

    property shape:

        def __get__(self):
            if (self.transpose_mode==enums.no_transpose or
                    self.transpose_mode==enums.conjugate_transpose):
                return self._op.shape
            else:
                return (self._op.shape[1],self._op.shape[0])

    property dtype:
        def __get__(self):
            return self._op.dtype

    def transpose(self):

        return SparseDiscreteBoundaryOperator(self._op.transpose())

    def conjugate(self):

        return SparseDiscreteBoundaryOperator(self._op.conjugate())

    def conjugate_transpose(self):

        return SparseDiscreteBoundaryOperator(self._op.conjugate().transpose())

        
cdef class HMatDiscreteBoundaryOperator(DiscreteBoundaryOperator):

    def __cinit__(self):
        pass

    def __init__(self):
        self.transpose_mode = enums.no_transpose
        

    def __dealloc__(self):
        pass

    def data(self, BlockClusterTreeNode node):
        cdef HMatrixData data = HMatrixData()

        try:
            if not (self.dtype=='float64' or self.dtype=='complex128'):
                raise ValueError("Unsupported dtype")

            if self.dtype=='float64':
                data.impl_float64_.assign(
                        deref(py_hmatrix_from_discrete_operator[double](self._impl_float64_)).data(node.impl_))
            else: 
                data.impl_complex128_.assign(
                        deref(py_hmatrix_from_discrete_operator[complex_double](self._impl_complex128_)).data(node.impl_))
        except:
            raise Exception("Could not obtain data associated with this block cluster node.")

        data._dtype = self.dtype

        if data.block_type=='dense':
            return down_cast_to_dense_data(data)
        elif data.block_type=='low_rank_ab':
            return down_cast_to_low_rank_data(data)
        else:
            raise Exception("Unsupported data block type.")


    property block_cluster_tree:

        def __get__(self):

            cdef BlockClusterTree tree = BlockClusterTree()

% for pyvalue, cyvalue in dtypes.items():
            if self.dtype=="${pyvalue}":
                tree.impl_.assign(
                        deref(py_hmatrix_from_discrete_operator[${cyvalue}](self._impl_${pyvalue}_)).blockClusterTree())
                return tree
% endfor

    property statistics:

        def __get__(self):
            from bempp.hmat.inspection import compression_statistics

            if self._statistics is None: 
                self._statistics = compression_statistics(self)

            return self._statistics

    property frobenius_norm:

        def __get__(self):
            if self.dtype=='float64':
                return deref(py_hmatrix_from_discrete_operator[double](self._impl_float64_)).frobeniusNorm()
            else:
                return deref(py_hmatrix_from_discrete_operator[complex_double](self._impl_complex128_)).frobeniusNorm()
 
    def _op_with_new_mode(self,mode):

        cdef HMatDiscreteBoundaryOperator res = HMatDiscreteBoundaryOperator()
        res._dtype = self.dtype
        if self.dtype=='float64':
            res._impl_float64_.assign(self._impl_float64_)
        elif self.dtype=='complex128':
            res._impl_complex128_.assign(self._impl_complex128_)
        else:
            raise NotImplementedError("Data type not supported.")
        res.transpose_mode = transposition_mode(mode)
        return res

cdef class BlockedDiscreteBoundaryOperator(DiscreteBoundaryOperatorBase):

    cdef np.ndarray _row_dimensions
    cdef np.ndarray _column_dimensions

    cdef np.ndarray _row_sums
    cdef np.ndarray _column_sums

    cdef np.ndarray _operators

    cdef object _shape

    def __cinit__(self,np.ndarray[long,ndim=1,mode='fortran'] row_dimensions, 
            np.ndarray[long,ndim=1,mode='fortran'] column_dimensions):
        pass

    def __init__(self,np.ndarray[long,ndim=1,mode='fortran'] row_dimensions, 
            np.ndarray[long,ndim=1,mode='fortran'] column_dimensions):
        self._row_dimensions = row_dimensions
        self._column_dimensions = column_dimensions
        self._row_sums = np.hstack(([0],np.cumsum(self._row_dimensions)))
        self._column_sums = np.hstack(([0],np.cumsum(self._column_dimensions)))

        self._shape = (self._row_sums[-1],self._column_sums[-1])

        self._operators = np.empty((len(self._row_dimensions),
                len(self._column_dimensions)),dtype=np.object)

        for i,row in enumerate(self._row_dimensions):
            for j,col in enumerate(self._column_dimensions):
                self._operators[i,j] = ZeroDiscreteBoundaryOperator(
                        row,col)
                
    property shape:

        def __get__(self):
            return self._shape

    property dtype:

        def __get__(self):
            cdef object dt = np.dtype('float64')
            for op in self._operators.ravel():
                dt = combined_type(dt,op.dtype)
            return dt

    property row_dimensions:
        
        def __get__(self):
            return self._row_dimensions

    property column_dimensions:
        
        def __get__(self):
            return self._column_dimensions

    property ndims:

        def __get__(self):
            return (len(self.row_dimensions),len(self.column_dimensions))

    def __getitem__(self,key):
        return self._operators[key]

    def __setitem__(self,key, DiscreteBoundaryOperatorBase op):

        if not (op.shape==self._operators[key].shape):
            raise ValueError("Wrong dimensions. Item has {0}, but expected is {1}".format(op.shape,self._operators[key].shape)) 

        self._operators[key] = op

    def as_matrix(self):

        res = np.empty(self.shape,dtype=self.dtype)
        for i in range(self.ndims[0]):
            for j in range(self.ndims[1]):
                res[self._row_sums[i]:self._row_sums[i+1],
                        self._column_sums[j]:self._column_sums[j+1]]=self._operators[i,j].as_matrix()
        return res

    def matvec(self,np.ndarray x):

        res = np.zeros((self.shape[0],x.shape[1]),dtype=self.dtype)

        for i in range(self.ndims[0]):
            for j in range(self.ndims[1]):
                res[self._row_sums[i]:self._row_sums[i+1],:] = res[self._row_sums[i]:self._row_sums[i+1],:] + self[i,j]*x[self._column_sums[j]:self._column_sums[j+1],:]
        return res

    def __mul__(self,object x):

        if not isinstance(self,DiscreteBoundaryOperatorBase):
            return x*self

        if np.isscalar(x):
            res = BlockedDiscreteBoundaryOperator(
                    self.row_dimensions,
                    self.column_dimensions)

            for i in range(self.ndims[0]):
                for j in range(self.ndims[1]):
                    res[i,j] = x*self[i,j]
            return res
        else:
            return super(BlockedDiscreteBoundaryOperator,self).__mul__(x)

    def __add__(self,DiscreteBoundaryOperatorBase other):

        if isinstance(other,BlockedDiscreteBoundaryOperator):

            if not (self.ndims==other.ndims and
                    np.all(self.row_dimensions-other.row_dimensions==0) and
                    np.all(self.column_dimensions-other.column_dimensions==0)):
                raise ValueError("Incompatible block structure.")

            res = BlockedDiscreteBoundaryOperator(
                    self.row_dimensions,
                    self.column_dimensions)

            for i in range(self.ndims[0]):
                for j in range(self.ndims[1]):
                    res[i,j] = self[i,j]+other[i,j]
            return res
        else:
            return super(BlockedDiscreteBoundaryOperator,self).__add__(other)
    
        
