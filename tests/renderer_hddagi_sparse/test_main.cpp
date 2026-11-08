#include "test_harness.h"

#include <cstring>

int main(int argc, char **argv) {
	for (int i = 1; i < argc; i++) {
		if (std::strcmp(argv[i], "--fixtures") == 0) {
			test::options().write_fixtures = true;
			if (i + 1 < argc && argv[i + 1][0] != '-') {
				test::options().fixtures_dir = argv[++i];
			}
		} else if (std::strcmp(argv[i], "--list") == 0) {
			for (const test::Case &c : test::registry()) {
				std::printf("%s\n", c.name);
			}
			return 0;
		}
	}
	return test::run_all();
}
