# Extra make rules, used as: make -f Makefile -f $SRC/mayhem/fuzz.mk <targets>
# Links the harnesses against the already-configured QEMU objects (same sets qemu-img links).
FUZZ_BINS = fuzz_net_eth fuzz_qobject_json fuzz_qemu_opts
LSAN_OFF = mayhem/lsan_off.o

HARNESS_CFLAGS = $(QEMU_INCLUDES) $(QEMU_CFLAGS) $(CFLAGS)

mayhem/%.o: $(SRC_PATH)/mayhem/%.c
	@mkdir -p mayhem
	$(CC) $(HARNESS_CFLAGS) -c -o $@ $<

mayhem/lsan_off.o: $(LSAN_OFF_SRC)
	@mkdir -p mayhem
	$(CC) $(HARNESS_CFLAGS) -c -o $@ $<

mayhem/standalone_main.o: $(STANDALONE_FUZZ_MAIN)
	@mkdir -p mayhem
	$(CC) $(HARNESS_CFLAGS) -c -o $@ $<

fuzz_net_eth: mayhem/fuzz_net_eth.o net/eth.o net/checksum.o $(COMMON_LDADDS) $(LSAN_OFF)
	$(call LINK, $^ $(LIB_FUZZING_ENGINE))
fuzz_net_eth-standalone: mayhem/fuzz_net_eth.o mayhem/standalone_main.o net/eth.o net/checksum.o $(COMMON_LDADDS) $(LSAN_OFF)
	$(call LINK, $^)

fuzz_qobject_json fuzz_qemu_opts: fuzz_%: mayhem/fuzz_%.o $(COMMON_LDADDS) $(LSAN_OFF)
	$(call LINK, $^ $(LIB_FUZZING_ENGINE))
fuzz_qobject_json-standalone fuzz_qemu_opts-standalone: fuzz_%-standalone: mayhem/fuzz_%.o mayhem/standalone_main.o $(COMMON_LDADDS) $(LSAN_OFF)
	$(call LINK, $^)

fuzz-all: $(FUZZ_BINS) $(addsuffix -standalone,$(FUZZ_BINS))
