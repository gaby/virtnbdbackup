if [ -z "$TEST" ]; then
    echo ""
    echo "Missing required test env" >&2
    echo "export TEST=<dir> to run specified tests" >&2
    echo ""
    exit
fi

if [ -e /root/agent ]; then
    source /root/agent > /dev/null
fi

if [ -z "$TMPDIR" ]; then
    export TMPDIR=$(mktemp -d)
    chmod go+rwx $TMPDIR
fi

load $TEST/config.bash
load agent-exec.sh


setup() {
 aa-teardown >/dev/null || true
}

@test "Setup / download vm image ${IMG_URL} to ${TMPDIR}/${VM_IMAGE}" {
    if [ ! -e ${TMPDIR}/${VM_IMAGE} ]; then
        curl -Ls ${IMG_URL} -o ${TMPDIR}/${VM_IMAGE}
    fi
}

@test "Setup: Define and start test VM ${VM}" {
    virsh destroy ${VM} || true
    echo "output = ${output}"
    virsh undefine ${VM} --remove-all-storage --checkpoints-metadata || true
    echo "output = ${output}"
    cp ${VM}/${VM}.xml ${TMPDIR}/
    sed -i "s|__TMPDIR__|${TMPDIR}|g" ${TMPDIR}/${VM}.xml
    run virsh define ${TMPDIR}/${VM}.xml
    echo "output = ${output}"
    run virsh start ${VM}
    echo "output = ${output}"
    [ "$status" -eq 0 ]
    echo "output = ${output}"
}
@test "Wait for VM to be reachable via guest agent" {
    run wait_for_agent $VM
}
@test "Backup: create full backup" {
    run ../virtnbdbackup -d $VM -l full -o ${TMPDIR}/fstrim
    [[ "${output}" =~  "Saved qcow image config" ]]
    [ "$status" -eq 0 ]
}
@test "Create data in VM 1" {
    run execute_qemu_command $VM "cp" '["-a", "/etc", "/incdata"]'
    echo "output = ${output}"
    [ "$status" -eq 0 ]
    run execute_qemu_command $VM sync
    [ "$status" -eq 0 ]
}
@test "Execute fstrim" {
    run execute_qemu_command $VM "fstrim" '["-v", "/"]'
    echo "trimmed = ${output}" >&3
    [ "$status" -eq 0 ]
}
@test "Create data in VM 2" {
    run execute_qemu_command $VM "cp" '["-a", "/etc", "/incdata2"]'
    echo "output = ${output}"
    [ "$status" -eq 0 ]
    run execute_qemu_command $VM sync
    [ "$status" -eq 0 ]
}
@test "Backup: create inc backup with sparse detection" {
    run ../virtnbdbackup -d $VM -l inc -o ${TMPDIR}/fstrim
    echo "output = ${output}"
    [[ "${output}" =~  "sparse blocks for current bitmap" ]]
    [ "$status" -eq 0 ]
}
@test "Create data in VM 3" {
    run execute_qemu_command $VM "cp" '["-a", "/etc", "/incdata3"]'
    [ "$status" -eq 0 ]
    run execute_qemu_command $VM sync
    [ "$status" -eq 0 ]
}
@test "Backup: create inc backup without sparse detection" {
    run ../virtnbdbackup -d $VM -l inc --no-sparse-detect -o ${TMPDIR}/fstrim
    echo "output = ${output}"
    [[ "${output}" =~  "Skipping detection of sparse" ]]
    [ "$status" -eq 0 ]
}
@test "Remove data in VM" {
    run execute_qemu_command $VM "rm" '["-rf", "/incdata3"]'
    [ "$status" -eq 0 ]
    run execute_qemu_command $VM sync
    [ "$status" -eq 0 ]
}
@test "Execute fstrim 2" {
    run execute_qemu_command $VM "fstrim" '["-v", "/"]'
    echo "trimmed = ${output}" >&3
    [ "$status" -eq 0 ]
}
@test "Backup: create inc backup again, with sparse detection" {
    run ../virtnbdbackup -d $VM -l inc -o ${TMPDIR}/fstrim
    echo "output = ${output}"
    [[ "${output}" =~  "sparse blocks for current bitmap" ]]
    [ "$status" -eq 0 ]
}
@test "Create data in VM 4 and create checksum" {
    run execute_qemu_command $VM "dd" '["if=/dev/urandom", "of=/testdata", "bs=1M", "count=500"]'
    [ "$status" -eq 0 ]
    run execute_qemu_command $VM sync
    [ "$status" -eq 0 ]
    run execute_qemu_command $VM "md5sum" '["/testdata"]'
    [ "$status" -eq 0 ]
    echo "checksum = ${output}"
    echo ${output} > ${TMPDIR}/data.sum
}
@test "Backup: create inc backup 4, with sparse detection" {
    run ../virtnbdbackup -d $VM -l inc --no-sparse-detect -o ${TMPDIR}/fstrim
    echo "output = ${output}"
    [ "$status" -eq 0 ]
}
@test "Run checksum verify" {
    run ../virtnbdrestore -a verify -i ${TMPDIR}/fstrim -o /tmp
    echo "output = ${output}"
    [ "$status" -eq 0 ]
}
@test "Restore: restore vm with new name" {
    run ../virtnbdrestore -cD --name restored -i ${TMPDIR}/fstrim -o ${TMPDIR}/restore
    echo "output = ${output}"
    [ "$status" -eq 0 ]
}
@test "Verify image contents" {
    run virt-ls -a ${TMPDIR}/restore/nosparsedetect.qcow2 /
    [[ "${output}" =~  "incdata" ]]
    [ "$status" -eq 0 ]

    run virt-ls -a ${TMPDIR}/restore/nosparsedetect.qcow2 /incdata
    [[ "${output}" =~  "sudoers" ]]
    [ "$status" -eq 0 ]

    run virt-cat -a ${TMPDIR}/restore/nosparsedetect.qcow2 /incdata/sudoers
    [[ "${output}" =~  "Uncomment" ]]
    [ "$status" -eq 0 ]

    run virt-ls -a ${TMPDIR}/restore/nosparsedetect.qcow2 /incdata2
    [[ "${output}" =~  "sudoers" ]]
    [ "$status" -eq 0 ]

    run virt-ls -a ${TMPDIR}/restore/nosparsedetect.qcow2 /incdata3
    [ "$status" -ne 0 ]
}
@test "Start restored VM" {
    run virsh start restored
    [ "$status" -eq 0 ]
}
@test "Verify restored VM boots" {
    run wait_for_agent restored
    [ "$status" -eq 0 ]
}
@test "Verify checksums of data backed up during incremental backup" {
    run execute_qemu_command restored "md5sum" '["/testdata"]'
    [ "$status" -eq 0 ]
    echo "checksum = ${output}"
    echo ${output} > ${TMPDIR}/restored.sum
    run cmp ${TMPDIR}/restored.sum ${TMPDIR}/data.sum
    echo "output = ${output}"
    [ "$status" -eq 0 ]
}
@test "Check filesystem consistency after boot" {
    run execute_qemu_command restored btrfs '["device","stats","-c", "/"]'
    [ "$status" -eq 0 ]
    echo "output = ${output}"
}
