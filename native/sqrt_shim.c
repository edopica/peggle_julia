/*
 * sqrt_shim.c - hidden hardware square root for CORE-MATH internal calls.
 *
 * CORE-MATH's binary64 asin/acos (and cold paths elsewhere) emit calls to a
 * `sqrt` symbol when compiled with GCC -frounding-math; the linker would
 * otherwise bind those calls to the host libm's sqrt, which the interface
 * spec forbids. Defining `sqrt` here with hidden visibility satisfies those
 * references inside the component only; the version script in
 * peggle_math.map keeps it out of the exported ABI.
 *
 * GCC maps __builtin_sqrt inside a function named `sqrt` back to that
 * function (infinite recursion), so the hardware instruction is used
 * directly. This is the hardware IEEE-754 square root, correctly rounded in
 * all rounding modes, identical to what __builtin_sqrt expands to elsewhere.
 *
 * The instruction is selected at compile time; the emitted code is the same
 * hardware operation on every supported architecture:
 *   x86-64   sqrtsd  (SSE2)
 *   aarch64  fsqrt   (AArch64 scalar floating-point square root)
 */
__attribute__((visibility("hidden")))
double
sqrt(double x)
{
#if defined(__x86_64__)
  double r;
  __asm__("sqrtsd %1, %0" : "=x"(r) : "x"(x));
  return r;
#elif defined(__aarch64__)
  double r;
  __asm__("fsqrt %d0, %d1" : "=w"(r) : "w"(x));
  return r;
#else
#error "sqrt_shim.c: no hardware square root branch for this architecture"
#endif
}
