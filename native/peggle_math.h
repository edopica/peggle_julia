/*
 * peggle_math.h - shared native math component for Peggle Evolved core math.
 *
 * Frozen interface version 1. See tmp/core-math/interface-spec.md.
 *
 * All arguments and results are IEEE-754 binary64. The component has no
 * errno contract and no float/long double variants.
 */
#ifndef PEGGLE_MATH_H
#define PEGGLE_MATH_H

#define PEGGLE_MATH_ABI_VERSION 1

#ifdef __cplusplus
extern "C" {
#endif

#if defined(_WIN32)
#  define PEGGLE_MATH_API __declspec(dllexport)
#elif defined(__GNUC__)
#  define PEGGLE_MATH_API __attribute__((visibility("default")))
#else
#  define PEGGLE_MATH_API
#endif

/* Returns PEGGLE_MATH_ABI_VERSION. */
PEGGLE_MATH_API int peggle_math_abi_version(void);

/* Static UTF-8 JSON identity string. Never NULL. */
PEGGLE_MATH_API const char *peggle_math_identity(void);

PEGGLE_MATH_API double peggle_math_sin(double x);
PEGGLE_MATH_API double peggle_math_cos(double x);
PEGGLE_MATH_API double peggle_math_tan(double x);
PEGGLE_MATH_API double peggle_math_asin(double x);
PEGGLE_MATH_API double peggle_math_acos(double x);
PEGGLE_MATH_API double peggle_math_atan(double x);
PEGGLE_MATH_API double peggle_math_atan2(double y, double x);
PEGGLE_MATH_API double peggle_math_exp(double x);
PEGGLE_MATH_API double peggle_math_log(double x);
PEGGLE_MATH_API double peggle_math_pow(double a, double b);
PEGGLE_MATH_API double peggle_math_sqrt(double x);

#ifdef __cplusplus
}
#endif

#endif /* PEGGLE_MATH_H */
