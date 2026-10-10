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
 * function (infinite recursion), so the SSE2 instruction is used directly.
 * This is the hardware IEEE-754 square root, correctly rounded in all
 * rounding modes, identical to what __builtin_sqrt expands to elsewhere.
 */
__attribute__((visibility("hidden")))
double
sqrt(double x)
{
  double r;
  __asm__("sqrtsd %1, %0" : "=x"(r) : "x"(x));
  return r;
}
