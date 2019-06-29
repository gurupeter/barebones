#include <kprint.h>
#include <cstdio>

#define frp(N, ra)                                 \
  (__builtin_frame_address(N) != nullptr) &&       \
  (ra = __builtin_return_address(N)) != nullptr && ra != (void*)-1

static void print_trace(const int N, const void* ra)
{
  static char buffer[4096];
  snprintf(buffer, sizeof(buffer),
          "[%d] %p\n",
          N, ra);
  kprint(buffer);
}

extern "C"
void print_backtrace()
{
  kprintf("\nBacktrace:\n");
  void* ra;
  if (frp(0, ra)) {
    print_trace(0, ra);
    if (frp(1, ra)) {
      print_trace(1, ra);
      if (frp(2, ra)) {
        print_trace(2, ra);
      }
    }
  }
}

extern "C"
__attribute__((noreturn))
void panic(const char* reason)
{
  kprintf("\n\n!!! PANIC !!!\n%s\n", reason);

  print_backtrace();

  // the end
  kprintf("\nKernel halting...\n");
  while (1) asm("cli; hlt");
  __builtin_unreachable();
}

extern "C"
void abort()
{
	panic("Abort called");
}
