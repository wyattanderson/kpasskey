#define _DARWIN_C_SOURCE
#include <cbor.h>
#include <dlfcn.h>
#include <fido.h>
#include <krb5.h>
#include <openssl/crypto.h>
#include <openssl/evp.h>
#include <profile.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <zlib.h>

#define CHECK(expr) do { if (!(expr)) { \
    fprintf(stderr, "probe failed at line %d: %s\n", __LINE__, #expr); \
    return 1; } } while (0)

int main(int argc, char **argv) {
    profile_t profile = NULL;
    krb5_context context = NULL;
    const char *relation[] = {"libdefaults", "default_realm", NULL};
    char *realm = NULL;
    CHECK(profile_init(NULL, &profile) == 0);
    CHECK(profile_add_relation(profile, relation, "BUILD.INVALID") == 0);
    CHECK(krb5_init_context_profile(profile, KRB5_INIT_CONTEXT_SECURE, &context) == 0);
    CHECK(krb5_get_default_realm(context, &realm) == 0);
    CHECK(strcmp(realm, "BUILD.INVALID") == 0);
    krb5_free_default_realm(context, realm);
    krb5_free_context(context);
    profile_release(profile);

    Dl_info origin;
    CHECK(dladdr((void *)krb5_init_context, &origin) != 0);
    CHECK(strstr(origin.dli_fname, "libkrb5.3.3.dylib") != NULL);
    CHECK(strstr(origin.dli_fname, "/System/") == NULL);
    fido_init(0);
    fido_assert_t *assertion = fido_assert_new();
    fido_dev_t *device = fido_dev_new();
    CHECK(assertion != NULL && device != NULL);
    fido_assert_free(&assertion);
    fido_dev_free(&device);
    cbor_item_t *item = cbor_build_uint8(42);
    CHECK(item != NULL && cbor_get_uint8(item) == 42);
    cbor_decref(&item);
    CHECK(OpenSSL_version_num() == OPENSSL_VERSION_NUMBER);
    CHECK(strcmp(zlibVersion(), ZLIB_VERSION) == 0);
    unsigned char digest[EVP_MAX_MD_SIZE];
    unsigned int digest_length = 0;
    CHECK(EVP_Digest("probe", 5, digest, &digest_length, EVP_sha256(), NULL) == 1);
    CHECK(digest_length == 32);
    unsigned char compressed[64], restored[64];
    uLongf compressed_length = sizeof(compressed), restored_length = sizeof(restored);
    CHECK(compress(compressed, &compressed_length, (const Bytef *)"probe", 5) == Z_OK);
    CHECK(uncompress(restored, &restored_length, compressed, compressed_length) == Z_OK);
    CHECK(restored_length == 5 && memcmp(restored, "probe", 5) == 0);

    if (argc == 2) {
        void *plugin = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
        if (plugin == NULL) { fprintf(stderr, "%s\n", dlerror()); return 1; }
        CHECK(dlsym(plugin, "clpreauth_pkinit_initvt") != NULL);
        CHECK(dlsym(plugin, "kdcpreauth_pkinit_initvt") != NULL);
        CHECK(dlsym(plugin, "krb5_init_context") == (void *)krb5_init_context);
        CHECK(dlclose(plugin) == 0);
    }
    printf("MIT profile/context, FIDO objects, CBOR, zlib %s, %s%s: OK\n",
           zlibVersion(), OpenSSL_version(OPENSSL_VERSION), argc == 2 ? ", PKINIT load" : "");
    return 0;
}
