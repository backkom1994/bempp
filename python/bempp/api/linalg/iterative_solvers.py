import scipy.sparse.linalg
from bempp.api.assembly import GridFunction
from bempp.api.assembly import BoundaryOperator

class _it_counter(object):

    def __init__(self):
        self._count = 0

    def __call__(self, x):
        self._count += 1

    @property
    def count(self):
        return self._count

def gmres(A, b, tol=1E-5, restart=None, maxiter=None):
    """Interface to the scipy.sparse.linalg.gmres function.

    This function behaves like the scipy.sparse.linalg.gmres function. But
    instead of a linear operator and a vector b it takes a boundary operator
    and a grid function. The result is returned as a grid function in the
    correct space.

    """
    import bempp.api
    import time

    if not isinstance(A, BoundaryOperator):
        raise ValueError("A must be of type BoundaryOperator")

    if not isinstance(b, GridFunction):
        raise ValueError("b must be of type GridFunction")

    # Assemble weak form before the logging messages

    A_op = A.weak_form()
    b_vec = b.projections(A.dual_to_range)

    callback = _it_counter()

    bempp.api.LOGGER.info("Starting GMRES iteration")
    start_time = time.time()
    x, info = scipy.sparse.linalg.gmres(A_op, b_vec,
                                        tol=tol, restart=restart, maxiter=maxiter, callback=callback)
    end_time = time.time()
    bempp.api.LOGGER.info("GMRES finished in {0} iterations and took {1:.2E} sec.".format(
        callback.count, end_time - start_time))

    return GridFunction(A.domain, coefficients=x.ravel()), info


def cg(A, b, tol=1E-5, maxiter=None):
    """Interface to the scipy.sparse.linalg.cg function.

    This function behaves like the scipy.sparse.linalg.cg function. But
    instead of a linear operator and a vector b it takes a boundary operator
    and a grid function. The result is returned as a grid function in the
    correct space.

    """
    import bempp.api
    import time

    if not isinstance(A, BoundaryOperator):
        raise ValueError("A must be of type BoundaryOperator")

    if not isinstance(b, GridFunction):
        raise ValueError("b must be of type GridFunction")

    A_op = A.weak_form()
    b_vec = b.projections(A.dual_to_range)

    callback = _it_counter()
    bempp.api.LOGGER.info("Starting CG iteration")
    start_time = time.time()
    x, info = scipy.sparse.linalg.cg(A_op, b_vec,
                                     tol=tol, maxiter=maxiter, callback=callback)
    end_time = time.time()
    bempp.api.LOGGER.info("CG finished in {0} iterations and took {1:.2E} sec.".format(
        callback.count, end_time - start_time))

    return GridFunction(A.domain, coefficients=x.ravel()), info
