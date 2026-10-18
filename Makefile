PRIV_DIR := $(MIX_APP_PATH)/priv
STORAGE_NIF := $(PRIV_DIR)/handbean_storage.so
ERTS_INCLUDE_DIR := $(shell erl -noshell -eval 'io:format("~s/erts-~s/include", [code:root_dir(), erlang:system_info(version)]), halt().')
CFLAGS ?= -O2 -fPIC -Wall -Wextra -Werror
ifeq ($(shell uname -s),Darwin)
LDFLAGS += -undefined dynamic_lookup
DARWIN_PROCESS_NIF := $(PRIV_DIR)/handbean_darwin_process.so
endif
NIFS := $(STORAGE_NIF) $(DARWIN_PROCESS_NIF)

.PHONY: all clean
all: $(NIFS)

$(STORAGE_NIF): c_src/handbean_storage.c
	@mkdir -p $(PRIV_DIR)
	$(CC) $(CFLAGS) -I$(ERTS_INCLUDE_DIR) -shared $(LDFLAGS) -o $@ $<

ifeq ($(shell uname -s),Darwin)
$(DARWIN_PROCESS_NIF): c_src/handbean_darwin_process.c
	@mkdir -p $(PRIV_DIR)
	$(CC) $(CFLAGS) -I$(ERTS_INCLUDE_DIR) -shared $(LDFLAGS) -o $@ $<
endif

clean:
	rm -f $(STORAGE_NIF) $(PRIV_DIR)/handbean_darwin_process.so
