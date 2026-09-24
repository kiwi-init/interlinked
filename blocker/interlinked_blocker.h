// C interface to blocker/src/lib.rs. All functions are thread-safe.
#ifndef INTERLINKED_BLOCKER_H_
#define INTERLINKED_BLOCKER_H_

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ILFilters ILFilters;
typedef struct ILBlocker ILBlocker;

enum { IL_ALLOW = 0, IL_BLOCK = 1, IL_REDIRECT = 2, IL_REWRITE = 3 };

ILFilters *il_filters_new(void);
void il_filters_add(ILFilters *filters, const char *list, bool trusted);
/// Consumes |filters|.
ILBlocker *il_blocker_new(ILFilters *filters, const char *resources_json);
ILBlocker *il_blocker_restore(const uint8_t *data, size_t length, const char *resources_json);
uint8_t *il_blocker_serialize(const ILBlocker *blocker, size_t *length);
void il_bytes_free(uint8_t *data, size_t length);
void il_blocker_free(ILBlocker *blocker);
void il_string_free(char *value);

/// For IL_REDIRECT |detail| is a data: URL to answer with; for IL_REWRITE it
/// is the URL to load instead. Release it with il_string_free.
int32_t il_blocker_check(const ILBlocker *blocker, const char *url, const char *source_url,
                         const char *request_type, const char *method, char **detail);
/// |url| without tracking parameters, or NULL when it has none. Release it
/// with il_string_free.
char *il_strip_tracking(const char *url);
/// JSON object: hide, exceptions, procedural, script, generichide.
char *il_blocker_cosmetics(const ILBlocker *blocker, const char *url);
/// |query_json| holds classes, ids, exceptions. Returns a JSON array.
char *il_blocker_generic_selectors(const ILBlocker *blocker, const char *query_json);

#ifdef __cplusplus
}
#endif

#endif  // INTERLINKED_BLOCKER_H_
