// Exercises the public CVE-2026-6653 fixture and the parser-option selection
// used by its reporter: https://bugs.launchpad.net/bugs/2141260
#include <fstream>
#include <functional>
#include <iterator>
#include <limits>
#include <string>
#include <libxml/parser.h>

static void quiet(void *, const char *, ...) {}

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    std::ifstream input(argv[1], std::ios::binary);
    if (!input) return 2;
    std::string data((std::istreambuf_iterator<char>(input)), {});
    int options = std::hash<std::string>{}(data) % std::numeric_limits<int>::max();
    options &= ~XML_PARSE_HUGE;
    xmlSetGenericErrorFunc(nullptr, quiet);
    for (int flags : {0, options}) {
        xmlDocPtr doc = xmlReadMemory(data.data(), data.size(), "noname.xml", nullptr, flags);
        if (doc) xmlFreeDoc(doc);
    }
    xmlCleanupParser();
    return 0;
}
