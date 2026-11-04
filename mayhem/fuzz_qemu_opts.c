/*
 * libFuzzer harness for QEMU's "-opt key=value,..." command-line option parser (util/qemu-option.c).
 */
#include "qemu/osdep.h"
#include "qapi/error.h"
#include "qapi/qmp/qdict.h"
#include "qapi/qmp/qjson.h"
#include "qapi/qmp/qstring.h"
#include "qemu/option.h"

static QemuOptsList typed_list = {
    .name = "fuzz-typed",
    .implied_opt_name = "str",
    .head = QTAILQ_HEAD_INITIALIZER(typed_list.head),
    .desc = {
        { .name = "str", .type = QEMU_OPT_STRING },
        { .name = "num", .type = QEMU_OPT_NUMBER },
        { .name = "flag", .type = QEMU_OPT_BOOL },
        { .name = "size", .type = QEMU_OPT_SIZE },
        { /* end */ }
    },
};

static QemuOptsList open_list = {
    .name = "fuzz-open",
    .head = QTAILQ_HEAD_INITIALIZER(open_list.head),
    .merge_lists = true,
    .desc = { { /* end */ } },
};

static void parse_with(QemuOptsList *list, const char *params, bool firstname, bool typed)
{
    Error *err = NULL;
    QemuOpts *opts = qemu_opts_parse(list, params, firstname, &err);
    if (!opts) {
        error_free(err);
        return;
    }
    if (typed) {
        qemu_opt_get(opts, "str");
        qemu_opt_get_number(opts, "num", 0);
        qemu_opt_get_bool(opts, "flag", false);
        qemu_opt_get_size(opts, "size", 0);
    }
    QDict *dict = qemu_opts_to_qdict(opts, NULL);
    QString *json = qobject_to_json(QOBJECT(dict));
    QDECREF(json);
    QDECREF(dict);
    qemu_opts_del(opts);
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
    char *params = g_malloc(size + 1);

    memcpy(params, data, size);
    params[size] = 0;
    parse_with(&typed_list, params, false, true);
    parse_with(&typed_list, params, true, true);
    parse_with(&open_list, params, false, false);
    g_free(params);
    return 0;
}
