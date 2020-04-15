// cemi abstractions
// https://www.dehof.de/eib/pdfs/EMI-FT12-Message-Format.pdf
module cemi;

import std.bitmanip;
import std.conv;
import std.stdio;

enum MC {
  unknown,
  LDATA_REQ = 0x11,
  LDATA_CON = 0x2E,
  LDATA_IND = 0x29,
  MPROPREAD_REQ = 0xFC,
  MPROPREAD_CON = 0xFB,
  MPROPWRITE_REQ = 0xF6,
  MPROPWRITE_CON = 0xF5,
  MPROPINFO_IND = 0xF7,
  MRESET_REQ = 0xF1,
  MRESET_IND = 0xF0
}

class LData_cEMI {
  public ubyte message_code;
  public int additional_info_len;
  public ubyte[] additional_info;

  // control field 1
  public ubyte cf1;
  public bool standard; // extended 0, standard 1
  public bool donorepeat; // 0 - repeat, 1 - do not
  public bool sys_broadcast;
  public ubyte priority;
  public bool ack_requested;
  public bool error; // 0 - no error(confirm)
  // control field 2
  public ubyte cf2;
  public bool address_type_group; // 0 - individual, 1 - group;
  public ubyte hop_count; 
  public ubyte ext_frame_format; // 0 - std frame

  public ushort source;
  public ushort dest;
  public ubyte apdu_data_len;
  public ubyte tpdu;
  public ubyte apdu;

  public ubyte tpci;
  public ubyte apci;
  public ubyte[] apdu_data;
  public ubyte[] data;

  this() {
    // empty
  }
  this(ubyte[] msg) {
    // parse frame
    auto offset = 0;
    message_code = msg.peek!ubyte(offset); offset += 1;
    additional_info_len = msg.peek!ubyte(offset); offset += 1;
    additional_info = msg[offset..offset + additional_info_len].dup;
    offset += additional_info_len;
    cf1 = msg.peek!ubyte(offset); offset += 1;
    cf2 = msg.peek!ubyte(offset); offset += 1;
    // extract info from cf1
    standard = to!bool(cf1 >> 7);
    donorepeat = to!bool((cf1 >> 5) & 0b1);
    sys_broadcast = to!bool((cf1 >> 4) & 0b1);
    priority = to!ubyte((cf1 >> 2) & 0b11);
    ack_requested = to!bool((cf1 >> 1) & 0b1);
    error = to!bool(cf1 & 0b1);
    // from cf2
    address_type_group = to!bool(cf2 >> 7);
    hop_count = to!ubyte((cf2 >> 4) & 0b111);
    ext_frame_format = to!ubyte(cf2 & 0b1111);

    // addresses
    source = msg.peek!ushort(offset); offset += 2;
    dest = msg.peek!ushort(offset); offset += 2;
    apdu_data_len = msg.peek!ubyte(offset); offset += 1;
    tpdu = msg.peek!ubyte(offset); offset += 1;
    apdu_data = msg[offset..offset + apdu_data_len].dup;
    
    if (apdu_data_len == 0) {
      tpci = tpdu;
      //apci = ((tpdu & 0b11) << 2);
      data.length = 0;
    } else if (apdu_data_len == 1) {
      tpci = tpdu >> 2;
      apci = ((tpdu & 0b11) << 2) | ((apdu_data[0] & 0b11000000) >> 6);
      data.length = apdu_data.length;
      data[0] = apdu_data[0] & 0b111111;
    } else if (apdu_data_len > 1) {
      tpci = tpdu >> 2;
      apci = ((tpdu & 0b11) << 2) | ((apdu_data[0] & 0b11000000) >> 6);
      data.length = apdu_data.length - 1;
      data[0..$] = apdu_data[1..$];
    }
  }
  public ubyte[] toUbytes() {
    ubyte[] result;
    result.length = 10 + additional_info_len + apdu_data_len;
    writeln("result length: ", result.length);
    auto offset = 0;
    result.write!ubyte(message_code, offset); offset += 1;
    result.write!ubyte(to!ubyte(additional_info_len & 0xff), offset); offset += 1;
    result[offset..offset + additional_info_len] = additional_info[0..$];
    offset += additional_info_len;
    // calculate cf1 and cf2
    cf1 = 0x00;
    if (standard) {
      cf1 = cf1 | 0b10000000;
    }
    if (donorepeat) {
      cf1 = cf1 | 0b00100000;
    }
    if (sys_broadcast) {
      cf1 = cf1 | 0b00010000;
    }
    cf1 = to!ubyte(cf1 | (priority << 2));
    if (ack_requested) {
      cf1 = cf1 | 0b00000010;
    }
    if (error) {
      cf1 = cf1 | 0b00000001;
    }

    cf2 = 0x00;
    if (address_type_group) {
      cf2 = cf2 | 0b10000000;
    }
    cf2 = to!ubyte(cf2 | (hop_count << 4));
    cf2 = cf2 | (ext_frame_format & 0b1111);

    result.write!ubyte(cf1, offset); offset += 1;
    result.write!ubyte(cf2, offset); offset += 1;
    result.write!ushort(source, offset); offset += 2;
    result.write!ushort(dest, offset); offset += 2;

    result.write!ubyte(apdu_data_len, offset); offset += 1;

    if (apdu_data_len == 0) {
      result.write!ubyte(tpci, offset); offset += 1;
    } else if (apdu_data_len == 1) {
      tpdu = to!ubyte(tpci << 2);
      tpdu = tpdu | (apci >> 2);
      result.write!ubyte(tpdu, offset); offset += 1;
      apdu_data.length = apdu_data_len;
      apdu_data[0] = (apci & 0b11) << 6;
      apdu_data[0] = apdu_data[0] | (data[0] & 0b111111);
      result[offset..$] = apdu_data[0..$];
    } else if (apdu_data_len > 1) {
      tpdu = to!ubyte(tpci << 2);
      tpdu = tpdu | (apci >> 2);
      result.write!ubyte(tpdu, offset); offset += 1;
      apdu_data.length = apdu_data_len;
      apdu_data[0] = (apci & 0b11) << 6;
      apdu_data[1..$] = data[0..$];
      result[offset..$] = apdu_data[0..$];
    }

    return result;
  }
}
