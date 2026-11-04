/*
 * libFuzzer harness for QEMU's JSON lexer/parser/emitter (the QMP wire format).
 */
#include "qemu/osdep.h"
#include "qapi/error.h"
#include "qapi/qmp/qjson.h"
#include "qapi/qmp/qobject.h"
#include "qapi/qmp/qstring.h"

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
    char *text = g_malloc(size + 1);
    Error *err = NULL;
    QObject *obj;
    QString *out;

    memcpy(text, data, size);
    text[size] = 0;

    obj = qobject_from_json(text, &err);
    if (obj) {
        out = qobject_to_json(obj);
        QDECREF(out);
        out = qobject_to_json_pretty(obj);
        QDECREF(out);
        qobject_decref(obj);
    } else {
        error_free(err);
    }
    g_free(text);
    return 0;
}
