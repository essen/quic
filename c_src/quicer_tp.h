#undef TRACEPOINT_PROVIDER
#define TRACEPOINT_PROVIDER quicer_tp

#undef TRACEPOINT_INCLUDE
#define TRACEPOINT_INCLUDE "./quicer_tp.h"

#if !defined(_QUICER_TP_H) || defined(TRACEPOINT_HEADER_MULTI_READ)
#define _QUICER_TP_H

#ifdef QUICER_USE_LTTNG
#include <lttng/tracepoint.h>

TRACEPOINT_EVENT(
    quicer_tp,
    callback,
    TP_ARGS(
        char*, name,
        int, mark
    ),
    TP_FIELDS(
        ctf_string(name, name)
        ctf_integer(int, mark, mark)
    )
)

TRACEPOINT_EVENT(
    quicer_tp,
    nif,
    TP_ARGS(
        char*, fun,
        int, mark
    ),
    TP_FIELDS(
        ctf_string(name, fun)
        ctf_integer(int, mark, mark)
    )
)


#define TP_NIF_2(NAME, ARG2) tracepoint(quicer_tp, nif, #NAME, ARG2)
#define TP_CB_2(NAME, ARG2)  tracepoint(quicer_tp, callback, #NAME, ARG2)

#else /* QUICER_USE_LTTNG */

#define TP_NIF_2(Arg1, Arg2) do {} while(0)
#define TP_CB_2(Arg1, Arg2)  do {} while(0)

#endif /* QUICER_USE_LTTNG */
#endif /* _QUICER_TP_H */

#ifdef QUICER_USE_LTTNG
#include <lttng/tracepoint-event.h>
#endif /* QUICER_USE_LTTNG */
