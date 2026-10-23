cmake -B build -G "MinGW Makefiles"
cmake --build build
ctest --test-dir build
