/*
 * smoke_test.c - sanity checks for libpeggle_math (ABI version 1).
 *
 * This is a smoke test only: it checks the ABI handshake, basic identity
 * JSON shape, and a handful of correctly-rounded values. Full correctness
 * comparison against an independent oracle is a later work package.
 *
 * Build and run via `native/build.sh --smoke` (or
 * `scripts/verify_core_math.sh`); do not link against the host libm for the
 * functions under test.
 */
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "peggle_math.h"

static int failures = 0;

static uint64_t
bits(double x)
{
  uint64_t u;
  memcpy(&u, &x, sizeof u);
  return u;
}

static void
check_bits(const char *what, double got, uint64_t want)
{
  if (bits(got) != want) {
    fprintf(stderr, "FAIL %s: got %a (0x%016llx), want 0x%016llx\n", what, got,
            (unsigned long long) bits(got), (unsigned long long) want);
    failures++;
  }
}

static void
check_true(const char *what, int cond)
{
  if (!cond) {
    fprintf(stderr, "FAIL %s\n", what);
    failures++;
  }
}

static int
is_hex40(const char *s)
{
  for (int n = 0; n < 40; n++) {
    if (!((s[n] >= '0' && s[n] <= '9') || (s[n] >= 'a' && s[n] <= 'f')))
      return 0;
  }
  return 1;
}

int
main(void)
{
  const char *id;

  check_true("abi_version == 1", peggle_math_abi_version() == 1);

  id = peggle_math_identity();
  check_true("identity not NULL", id != NULL);
  if (id != NULL) {
    check_true("identity starts with '{'", id[0] == '{');
    check_true("identity ends with '}'", id[strlen(id) - 1] == '}');
    check_true("identity contains \"abi_version\"",
               strstr(id, "\"abi_version\"") != NULL);
    check_true("identity contains ABI value 1",
               strstr(id, "\"abi_version\":1") != NULL);
    check_true("identity contains name", strstr(id, "\"name\":\"peggle_math\"") != NULL);
    check_true("identity contains sqrt marker",
               strstr(id, "\"sqrt_implementation\":\"hardware-ieee754\"") != NULL);
    {
      const char *rev = strstr(id, "\"core_math_revision\":\"");
      check_true("identity contains core_math_revision", rev != NULL);
      if (rev != NULL) {
        rev += strlen("\"core_math_revision\":\"");
        check_true("core_math_revision is 40 lowercase hex", is_hex40(rev));
      }
    }
  }

  check_bits("sin(+0.0)", peggle_math_sin(0.0), 0x0000000000000000ull);
  check_bits("sin(-0.0)", peggle_math_sin(-0.0), 0x8000000000000000ull);
  check_bits("cos(0.0)", peggle_math_cos(0.0), 0x3ff0000000000000ull);
  check_bits("sin(1.0)", peggle_math_sin(1.0), 0x3feaed548f090ceeull);
  check_bits("cos(1.0)", peggle_math_cos(1.0), 0x3fe14a280fb5068cull);
  check_bits("tan(0.0)", peggle_math_tan(0.0), 0x0000000000000000ull);
  check_bits("asin(0.0)", peggle_math_asin(0.0), 0x0000000000000000ull);
  check_bits("acos(1.0)", peggle_math_acos(1.0), 0x0000000000000000ull);
  check_bits("atan(1.0)", peggle_math_atan(1.0), 0x3fe921fb54442d18ull);
  check_bits("atan2(1.0,1.0)", peggle_math_atan2(1.0, 1.0),
             0x3fe921fb54442d18ull);
  check_bits("exp(0.0)", peggle_math_exp(0.0), 0x3ff0000000000000ull);
  check_bits("log(1.0)", peggle_math_log(1.0), 0x0000000000000000ull);
  check_bits("pow(2.0,10.0)", peggle_math_pow(2.0, 10.0),
             0x4090000000000000ull);
  check_bits("sqrt(4.0)", peggle_math_sqrt(4.0), 0x4000000000000000ull);

  check_true("sqrt(-1.0) is NaN", isnan(peggle_math_sqrt(-1.0)));
  check_true("sqrt(INFINITY) is +Inf",
             isinf(peggle_math_sqrt(INFINITY)) &&
                 peggle_math_sqrt(INFINITY) > 0);
  check_true("log(0.0) is -Inf",
             isinf(peggle_math_log(0.0)) && peggle_math_log(0.0) < 0);
  check_true("acos(2.0) is NaN", isnan(peggle_math_acos(2.0)));

  if (failures != 0) {
    fprintf(stderr, "smoke test FAILED with %d failure(s)\n", failures);
    return 1;
  }
  printf("smoke test OK (ABI %d)\n", peggle_math_abi_version());
  return 0;
}
