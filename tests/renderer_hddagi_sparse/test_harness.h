// Minimal dependency-free test harness.
//
// Deliberately not GoogleTest: the CPU oracle must compile anywhere, including a
// machine with no package manager, and later inside the engine tree where an
// external test framework may not be vendored.

#pragma once

#include <cstdio>
#include <cstdlib>
#include <string>
#include <type_traits>
#include <vector>

namespace test {

struct Case {
	const char *name;
	void (*fn)();
};

inline std::vector<Case> &registry() {
	static std::vector<Case> cases;
	return cases;
}

struct Registrar {
	Registrar(const char *name, void (*fn)()) { registry().push_back({ name, fn }); }
};

struct Options {
	std::string fixtures_dir = "fixtures";
	bool write_fixtures = false;
};

inline Options &options() {
	static Options o;
	return o;
}

inline int &failure_count() {
	static int failures = 0;
	return failures;
}

inline const char *&current_case() {
	static const char *name = "";
	return name;
}

inline void report_failure(const char *file, int line, const std::string &message) {
	std::fprintf(stderr, "  FAIL %s:%d  [%s]\n    %s\n", file, line, current_case(), message.c_str());
	failure_count()++;
}

inline std::string describe(const std::string &v) {
	return v.empty() ? "<empty>" : v;
}

template <typename T>
inline std::string describe(const T &v) {
	if constexpr (std::is_enum_v<T>) {
		return std::to_string(static_cast<long long>(v));
	} else if constexpr (std::is_arithmetic_v<T>) {
		return std::to_string(v);
	} else {
		return "<value>";
	}
}

template <typename A, typename B>
inline void check_eq(const char *file, int line, const A &a, const B &b, const char *expr_a, const char *expr_b) {
	if (!(a == b)) {
		report_failure(file, line, std::string(expr_a) + " == " + expr_b + "  (" + describe(a) + " vs " + describe(b) + ")");
	}
}

inline int run_all() {
	int failed_cases = 0;
	for (const Case &c : registry()) {
		current_case() = c.name;
		const int before = failure_count();
		c.fn();
		if (failure_count() != before) {
			failed_cases++;
		}
	}
	const int total = int(registry().size());
	if (failure_count() == 0) {
		std::printf("PASS  %d cases, 0 failures\n", total);
		return 0;
	}
	std::printf("FAIL  %d cases, %d failed, %d assertion failures\n", total, failed_cases, failure_count());
	return 1;
}

} // namespace test

#define TEST(name)                                                    \
	static void name();                                               \
	static test::Registrar registrar_##name(#name, &name);            \
	static void name()

#define CHECK(cond)                                                   \
	do {                                                              \
		if (!(cond)) {                                                \
			test::report_failure(__FILE__, __LINE__, #cond);          \
		}                                                             \
	} while (0)

#define CHECK_EQ(a, b) test::check_eq(__FILE__, __LINE__, (a), (b), #a, #b)

#define REQUIRE(cond)                                                 \
	do {                                                              \
		if (!(cond)) {                                                \
			test::report_failure(__FILE__, __LINE__, #cond);          \
			return;                                                   \
		}                                                             \
	} while (0)
