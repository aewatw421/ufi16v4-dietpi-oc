#!/usr/bin/env node
// Build a valid GPT for the UFI_16__V4 stick.
//
// The OpenStick base.zip ships "gpt_both0.bin", which is a *prototype* table:
// its backup header sits at LBA 66 (inside what would be the primary entry
// array of a real disk), AltLBA is 0, and the rootfs entry has length 0.
// Qualcomm's flashing tools expand it at write time. Writing it verbatim onto
// a real disk yields a table with no usable backup header and a zero-length
// rootfs, so we generate a proper primary + backup GPT instead.
//
// Partition starts and type GUIDs are taken from the prototype, so stock aboot
// still finds what it expects:
//
//   cdt      131072   sbl1     262144   rpm      263168   tz       264192
//   hyp      266240   sec      267264   modemst1 267296   modemst2 271392
//   fsc      275488   fsg      393216   aboot    524288   boot     526336
//   devinfo  657408   rootfs   659456 (grows to the end of the disk)
//
// Usage: make-gpt.js --output IMAGE [--print-layout] [--disk-guid GUID]
'use strict';

const fs = require('fs');
const crypto = require('crypto');

const SECTOR = 512;
const ENTRY_COUNT = 128;
const ENTRY_SIZE = 128;

// name, first LBA, last LBA (null = grow to end), type GUID, unique GUID, attrs
const PARTITIONS = [
  ['cdt',      131072, 131075, 'a19f205f-ccd8-4b6d-8f1e-2d9bc24cffb1', '18285060-b8c8-7cf7-2823-fd5dd2956b88', 1n << 60n],
  ['sbl1',     262144, 263167, 'dea0ba2c-cbdd-4805-b4f9-f428251c3e98', '534641ab-51f1-f296-cf79-26e9c92e9002', 0n],
  ['rpm',      263168, 264191, '098df793-d712-413d-9d4e-89d711772228', '4cd3470f-02ef-5e92-c4f4-14bb5251e8f1', 0n],
  ['tz',       264192, 266239, 'a053aa7f-40b8-4b1c-ba08-2f68ac71a4f4', '0929ef2f-5cbe-b222-9aff-64578c4e1feb', 0n],
  ['hyp',      266240, 267263, 'e1a6a689-0c8d-4cc6-b4e8-55a4320fbd8a', 'bf2ea2b6-9f32-b528-99bb-c856cd988976', 0n],
  ['sec',      267264  , 267295, '303e6ac3-af15-4c54-9e9b-d9a8fbecf401', 'db68eec7-4c13-bc28-f720-2241bb41d057', 0n],
  ['modemst1', 267296, 271391, 'ebbeadaf-22c9-e33b-8f5d-0e81686a68cb', 'f4c8387d-6628-200b-82cc-16025907d272', 0n],
  ['modemst2', 271392, 275487, '0a288b1f-22c9-e33b-8f5d-0e81686a68cb', '45ba3e2a-d277-68a3-4a11-748d8ef623af', 0n],
  ['fsc',      275488, 275489, '57b90a16-22c9-e33b-8f5d-0e81686a68cb', '28fa1c81-5b9f-3a57-290b-e8ca46eb0055', 0n],
  ['fsg',      393216, 397311, '638ff8e2-22c9-e33b-8f5d-0e81686a68cb', '0d6c74b1-89bd-841e-4b2e-b7b23246967b', 1n << 60n],
  ['aboot',    524288, 526335, '400ffdcd-22e0-47e7-9a23-f16ed9382388', '2432ce91-198e-589b-5d6c-1e2953615a38', 0n],
  ['boot',     526336, 657407, '20117f86-e985-4357-b9ee-374bc1d8487d', '80780b1d-0fe1-27d3-23e4-9244e62f8c46', 0n],
  ['devinfo',  657408, 659455, '1b81e7e6-f50d-419b-a739-2aeef8da3335', '8b46880a-3de7-53e5-1e74-4602f82e1993', 0n],
  ['rootfs',   659456, null,   '97d7b011-54da-4835-b3c4-917ad6e73d74', 'a7ab80e8-e9d1-e8cd-f157-93f69b1d141e', 0n],
];

const DEFAULT_DISK_GUID = 'cf8a70db-042e-e28d-bafe-30c9b26444c5';

function crc32(buf) {
  let crc = 0xffffffff;
  for (let i = 0; i < buf.length; i++) {
    let c = (crc ^ buf[i]) & 0xff;
    for (let k = 0; k < 8; k++) c = (c & 1) ? (0xedb88320 ^ (c >>> 1)) : (c >>> 1);
    crc = (crc >>> 8) ^ c;
  }
  return (crc ^ 0xffffffff) >>> 0;
}

// GUID text -> the 16 on-disk bytes (first three fields little endian).
function guidBytes(text) {
  const hex = text.replace(/-/g, '');
  if (hex.length !== 32) throw new Error(`bad GUID: ${text}`);
  const b = Buffer.from(hex, 'hex');
  return Buffer.concat([
    Buffer.from([b[3], b[2], b[1], b[0]]),
    Buffer.from([b[5], b[4]]),
    Buffer.from([b[7], b[6]]),
    b.subarray(8, 16),
  ]);
}

function buildEntries(diskSectors) {
  const entries = Buffer.alloc(ENTRY_COUNT * ENTRY_SIZE);
  const layout = [];
  const lastUsable = diskSectors - 34; // backup header + 32 entry sectors

  PARTITIONS.forEach(([name, first, lastOrNull, typeGuid, uniqueGuid, attrs], i) => {
    const last = lastOrNull === null ? lastUsable : lastOrNull;
    if (last < first) throw new Error(`${name}: empty range ${first}..${last}`);
    if (last > lastUsable) throw new Error(`${name}: ends past usable area (${last} > ${lastUsable})`);
    const o = i * ENTRY_SIZE;
    guidBytes(typeGuid).copy(entries, o);
    guidBytes(uniqueGuid).copy(entries, o + 16);
    entries.writeBigUInt64LE(BigInt(first), o + 32);
    entries.writeBigUInt64LE(BigInt(last), o + 40);
    entries.writeBigUInt64LE(attrs, o + 48);
    entries.write(name, o + 56, 'utf16le');
    layout.push({ name, first, last });
  });

  const sorted = [...layout].sort((a, b) => a.first - b.first);
  for (let i = 1; i < sorted.length; i++) {
    if (sorted[i].first <= sorted[i - 1].last) {
      throw new Error(`overlap: ${sorted[i - 1].name} ends ${sorted[i - 1].last}, ${sorted[i].name} starts ${sorted[i].first}`);
    }
  }
  return { entries, layout };
}

function buildHeader({ myLba, altLba, firstUsable, lastUsable, diskGuid, entryLba, entries }) {
  const h = Buffer.alloc(SECTOR);
  h.write('EFI PART', 0, 'ascii');
  h.writeUInt32LE(0x00010000, 8);   // revision 1.0
  h.writeUInt32LE(92, 12);          // header size
  h.writeUInt32LE(0, 16);           // CRC placeholder
  h.writeUInt32LE(0, 20);           // reserved
  h.writeBigUInt64LE(BigInt(myLba), 24);
  h.writeBigUInt64LE(BigInt(altLba), 32);
  h.writeBigUInt64LE(BigInt(firstUsable), 40);
  h.writeBigUInt64LE(BigInt(lastUsable), 48);
  guidBytes(diskGuid).copy(h, 56);
  h.writeBigUInt64LE(BigInt(entryLba), 72);
  h.writeUInt32LE(ENTRY_COUNT, 80);
  h.writeUInt32LE(ENTRY_SIZE, 84);
  h.writeUInt32LE(crc32(entries), 88);
  h.writeUInt32LE(crc32(h.subarray(0, 92)), 16);
  return h;
}

function buildMbr(diskSectors) {
  const mbr = Buffer.alloc(SECTOR);
  const e = 446;
  mbr[e + 0] = 0x00;
  mbr[e + 1] = 0x00; mbr[e + 2] = 0x02; mbr[e + 3] = 0x00;   // start CHS
  mbr[e + 4] = 0xee;                                          // protective
  mbr[e + 5] = 0xfe; mbr[e + 6] = 0xff; mbr[e + 7] = 0xff;   // end CHS
  mbr.writeUInt32LE(1, e + 8);
  mbr.writeUInt32LE(Math.min(diskSectors - 1, 0xffffffff), e + 12);
  mbr[510] = 0x55; mbr[511] = 0xaa;
  return mbr;
}

function parseArgs(argv) {
  const opts = { output: null, printLayout: false, diskGuid: DEFAULT_DISK_GUID };
  for (let i = 0; i < argv.length; i++) {
    switch (argv[i]) {
      case '--output': opts.output = argv[++i]; break;
      case '--print-layout': opts.printLayout = true; break;
      case '--disk-guid': opts.diskGuid = argv[++i]; break;
      case '-h': case '--help':
        console.log('usage: make-gpt.js --output IMAGE [--print-layout] [--disk-guid GUID]');
        process.exit(0);
      default: throw new Error(`unknown argument: ${argv[i]}`);
    }
  }
  if (!opts.output) throw new Error('--output is required');
  return opts;
}

function main() {
  const opts = parseArgs(process.argv.slice(2));
  const size = fs.statSync(opts.output).size;
  if (size % SECTOR) throw new Error(`image size ${size} is not a multiple of ${SECTOR}`);
  const diskSectors = size / SECTOR;
  if (diskSectors < 700000) throw new Error('image is too small for this layout (need >= ~342 MiB)');

  const { entries, layout } = buildEntries(diskSectors);

  if (opts.printLayout) {
    for (const { name, first, last } of layout) {
      const mib = ((last - first + 1) * SECTOR) / 1048576;
      console.log(`${name.padEnd(10)} ${String(first).padStart(9)} .. ${String(last).padStart(9)}  ${mib.toFixed(1).padStart(8)} MiB`);
    }
    return;
  }

  const firstUsable = 34;
  const lastUsable = diskSectors - 34;
  const backupEntriesLba = diskSectors - 33;
  const backupHeaderLba = diskSectors - 1;

  const primary = buildHeader({ myLba: 1, altLba: backupHeaderLba, firstUsable, lastUsable,
                                diskGuid: opts.diskGuid, entryLba: 2, entries });
  const backup = buildHeader({ myLba: backupHeaderLba, altLba: 1, firstUsable, lastUsable,
                               diskGuid: opts.diskGuid, entryLba: backupEntriesLba, entries });

  const fd = fs.openSync(opts.output, 'r+');
  try {
    const write = (buf, lba) => fs.writeSync(fd, buf, 0, buf.length, lba * SECTOR);
    write(buildMbr(diskSectors), 0);
    write(primary, 1);
    write(entries, 2);
    write(entries, backupEntriesLba);
    write(backup, backupHeaderLba);
  } finally {
    fs.closeSync(fd);
  }

  console.log(`GPT written: ${diskSectors} sectors (${(size / 1048576).toFixed(1)} MiB)`);
  for (const { name, first, last } of layout) {
    const mib = ((last - first + 1) * SECTOR) / 1048576;
    console.log(`  ${name.padEnd(10)} ${String(first).padStart(9)} .. ${String(last).padStart(9)}  ${mib.toFixed(1).padStart(8)} MiB`);
  }
}

try {
  main();
} catch (err) {
  console.error(`make-gpt: ${err.message}`);
  process.exit(1);
}
