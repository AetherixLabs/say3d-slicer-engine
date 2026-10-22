// Force-included into every C++ file of the Android build (-include).
// OrcaSlicer leans on headers its desktop PCH (and other standard libraries)
// pull in transitively; NDK libc++ does not, so name them here.
#pragma once
#ifdef __cplusplus
#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>
#include <fstream>
#include <functional>
#include <iomanip>
#include <iostream>
#include <limits>
#include <map>
#include <memory>
#include <optional>
#include <set>
#include <sstream>
#include <string>
#include <vector>
#endif
