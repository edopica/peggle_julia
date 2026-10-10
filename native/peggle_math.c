/*
 * peggle_math.c - versioned C ABI over pinned CORE-MATH binary64 routines.
 *
 * ABI version 1. See native/peggle_math.h and
 * tmp/core-math/interface-spec.md.
 *
 * This file contains no mathematical algorithms. Each wrapper forwards
 * directly to the corresponding upstream CORE-MATH entry point:
 *
 *   peggle_math_sin   -> cr_sin
 *   peggle_math_cos   -> cr_cos
 *   peggle_math_tan   -> cr_tan
 *   peggle_math_asin  -> cr_asin
 *   peggle_math_acos  -> cr_acos
 *   peggle_math_atan  -> cr_atan
 *   peggle_math_atan2 -> cr_atan2
 *   peggle_math_exp   -> cr_exp
 *   peggle_math_log   -> cr_log
 *   peggle_math_pow   -> cr_pow
 *
 * peggle_math_sqrt uses the hardware IEEE-754 square root through
 * __builtin_sqrt with -fno-math-errno (recorded in build.json and in the
 * identity JSON as sqrt_implementation "hardware-ieee754").
 *
 * PEGGLE_MATH_IDENTITY_JSON comes from the build-generated header
 * native/build_generated/identity.h (written by native/build.sh).
 */
#include "peggle_math.h"

#include "build_generated/identity.h"

extern double cr_sin(double x);
extern double cr_cos(double x);
extern double cr_tan(double x);
extern double cr_asin(double x);
extern double cr_acos(double x);
extern double cr_atan(double x);
extern double cr_atan2(double y, double x);
extern double cr_exp(double x);
extern double cr_log(double x);
extern double cr_pow(double a, double b);

PEGGLE_MATH_API int
peggle_math_abi_version(void)
{
  return PEGGLE_MATH_ABI_VERSION;
}

PEGGLE_MATH_API const char *
peggle_math_identity(void)
{
  return PEGGLE_MATH_IDENTITY_JSON;
}

PEGGLE_MATH_API double
peggle_math_sin(double x)
{
  return cr_sin(x);
}

PEGGLE_MATH_API double
peggle_math_cos(double x)
{
  return cr_cos(x);
}

PEGGLE_MATH_API double
peggle_math_tan(double x)
{
  return cr_tan(x);
}

PEGGLE_MATH_API double
peggle_math_asin(double x)
{
  return cr_asin(x);
}

PEGGLE_MATH_API double
peggle_math_acos(double x)
{
  return cr_acos(x);
}

PEGGLE_MATH_API double
peggle_math_atan(double x)
{
  return cr_atan(x);
}

PEGGLE_MATH_API double
peggle_math_atan2(double y, double x)
{
  return cr_atan2(y, x);
}

PEGGLE_MATH_API double
peggle_math_exp(double x)
{
  return cr_exp(x);
}

PEGGLE_MATH_API double
peggle_math_log(double x)
{
  return cr_log(x);
}

PEGGLE_MATH_API double
peggle_math_pow(double a, double b)
{
  return cr_pow(a, b);
}

PEGGLE_MATH_API double
peggle_math_sqrt(double x)
{
  return __builtin_sqrt(x);
}
