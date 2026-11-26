/* Built by the Dockerfile with Triton's own build step: proves the image has the C compiler and Python's headers that
   Triton needs at run time for its CUDA helper module. */
#include <Python.h>

static struct PyModuleDef compiler_check = {PyModuleDef_HEAD_INIT, "compiler_check", NULL, -1, NULL};

PyMODINIT_FUNC PyInit_compiler_check(void) {
    return PyModule_Create(&compiler_check);
}
