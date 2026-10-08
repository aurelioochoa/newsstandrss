// Posts a Darwin notification on the phone: notify <name>
#include <notify.h>
int main(int argc, char *argv[]) { return argc == 2 ? (int)notify_post(argv[1]) : 64; }
