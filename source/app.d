import core.thread;
import std.algorithm.comparison : equal;
import std.base64;
import std.bitmanip;
import std.json;
import std.functional;
import std.stdio;

import clid;
import clid.validate;

import baos_ll;
import cemi;
import redis_dsm;
import errors;

enum CEMI_FROM_BAOS = "from_baos";
enum CEMI_TO_BAOS = "to_baos";

// struct for commandline params
private struct Config {
  @Parameter("config_prefix", 'c')
    @Description("Prefix for config key names. dobaosll_config_uart_device, etc.. Default: dobaosll_config_")
    string config_prefix;

  @Parameter("device", 'd')
    @Description("UART device. Setting this argument will overwrite redis key value. Default: /dev/ttyAMA0")
    string device;
}

void main() {
  writeln("hello, friend");

  // baos global
  BaosLL baos;

  auto dsm = new RedisDsm("127.0.0.1", cast(ushort)6379);

  auto config = parseArguments!Config();
  string config_prefix = config.config_prefix.length > 1 ? config.config_prefix: "dobaosll_config_";

  auto device = dsm.getKey(config_prefix ~ "uart_device", "/dev/ttyAMA0", true);
  // if device parameter was given in commandline arguments
  if (config.device.length > 1) {
    device = config.device;
    dsm.setKey(config_prefix ~ "uart_device", device);
  }
  auto params = dsm.getKey(config_prefix ~ "uart_params", "19200:8E1", true);

  auto req_channel = dsm.getKey(config_prefix ~ "req_channel", "dobaosll_req", true);
  auto cast_channel = dsm.getKey(config_prefix ~ "bcast_channel", "dobaosll_cast", true);
  dsm.setChannels(req_channel, cast_channel);

  auto stream_prefix = dsm.getKey(config_prefix ~ "stream_prefix", "dobaosll_stream_", true);
  auto stream_maxlen = dsm.getKey(config_prefix ~ "stream_maxlen", "100000", true);

  void handleRequest(JSONValue jreq, void delegate(JSONValue) sendResponse) {
    JSONValue res;

    auto jmethod = ("method" in jreq);
    if (jmethod is null) {
      res["success"] = false;
      res["payload"] = Errors.no_method_field.message;
      sendResponse(res);
      return;
    }
    auto jpayload = ("payload" in jreq);
    if (jpayload is null) {
      res["success"] = false;
      res["payload"] = Errors.no_payload_field.message;
      sendResponse(res);
      return;
    }

    string method = ("method" in jreq).str;
    switch(method) {
      case "cemi to bus":
        try {
          res["method"] = "success";
          if (jreq["payload"].type() != JSONType.string) {
            throw Errors.wrong_payload_type;
          }
          ubyte[] cemi;
          try {
            cemi = Base64.decode(jreq["payload"].str);
          } catch (Base64Exception) {
            throw Errors.wrong_base64_string;
          }
          baos.sendFT12Frame(cemi);
          res["payload"] = true;
          sendResponse(res);

          writeln("====================================================");
          writeln("sending cemi: ");

          // add to redis stream
          auto jstream = parseJSON("[]");
          jstream.array ~= JSONValue(CEMI_TO_BAOS); // 1 - to bus
          jstream.array ~= jreq["payload"];
          dsm.addToStream(stream_prefix, stream_maxlen, jstream);
          // process cemi
          auto mc = cemi.peek!ubyte(0);
          if (mc == MC.LDATA_REQ || mc == MC.LDATA_CON || mc == MC.LDATA_IND) {
            auto decoded = new LData_cEMI(cemi);
            writefln("orig frame: %(%x %)", cemi);
            writeln("mc: ", decoded.message_code);
            writeln("standard: ", decoded.standard);
            writeln("donorepeat: ", decoded.donorepeat);
            writeln("sys_broadcast: ", decoded.sys_broadcast);
            writeln("priority: ", decoded.priority);
            writeln("ack_requested: ", decoded.ack_requested);
            writeln("error: ", decoded.error);
            writeln("address_type_group: ", decoded.address_type_group);
            writeln("hop_count: ", decoded.hop_count);
            writeln("source: ", decoded.source);
            writeln("dest: ", decoded.dest);
            writeln("tpci: ", decoded.tpci);
            writeln("apci: ", decoded.apci, " == ", cast(ushort)decoded.apci);
            writeln("data: ", decoded.data);
            writeln("tservice: ", decoded.tservice);
            writeln("tsequence: ", decoded.tseq);
            writefln("toUbytes: %(%x %)", decoded.toUbytes());
            writeln("original and calculated equal? ", equal(cemi, decoded.toUbytes()));
            writeln("====================================================");
          }
        } catch(Exception e) {
          res["method"] = "error";
          res["payload"] = e.message;
          sendResponse(res);
        }
        break;
      default:
        res["method"] = "error";
        res["payload"] = Errors.unknown_method.message;
        sendResponse(res);
        break;
    }
  }
  dsm.subscribe(toDelegate(&handleRequest));

  baos = new BaosLL(device, params);
  void onCemiFrame(ubyte[] cemi) {
    auto jcast = parseJSON("{}");
    jcast["method"] = "cemi from bus";
    jcast["payload"] = Base64.encode(cemi);
    dsm.broadcast(jcast);
    
    writeln("====================================================");
    writefln("received cemi frame: %(%x %)", cemi);

    // add to redis stream
    auto jstream = parseJSON("[]");
    jstream.array ~= JSONValue(CEMI_FROM_BAOS); // 1 - to bus
    jstream.array ~= jcast["payload"];
    dsm.addToStream(stream_prefix, stream_maxlen, jstream);

    auto mc = cemi.peek!ubyte(0);
    if (mc == MC.LDATA_REQ || mc == MC.LDATA_CON || mc == MC.LDATA_IND) {
      auto decoded = new LData_cEMI(cemi);
      writefln("orig frame: %(%x %)", cemi);
      writeln("mc: ", decoded.message_code);
      writeln("standard: ", decoded.standard);
      writeln("donorepeat: ", decoded.donorepeat);
      writeln("sys_broadcast: ", decoded.sys_broadcast);
      writeln("priority: ", decoded.priority);
      writeln("ack_requested: ", decoded.ack_requested);
      writeln("error: ", decoded.error);
      writeln("address_type_group: ", decoded.address_type_group);
      writeln("hop_count: ", decoded.hop_count);
      writeln("source: ", decoded.source);
      writeln("dest: ", decoded.dest);
      writeln("tpci: ", decoded.tpci);
      writeln("apci: ", decoded.apci, " == ", cast(ushort)decoded.apci);
      writeln("data: ", decoded.data);
      writeln("tservice: ", decoded.tservice);
      writeln("tsequence: ", decoded.tseq);
      writefln("toUbytes: %(%x %)", decoded.toUbytes());
      writeln("original and calculated equal? ", equal(cemi, decoded.toUbytes()));
      writeln("====================================================");
    }
  }
  baos.onCemiFrame = toDelegate(&onCemiFrame);
  writeln("BAOS instance created");
  Thread.sleep(10.msecs);
  baos.reset();
  baos.switch2LL();
  writeln("Switching to LinkLayer");
  writeln("Working....");

  /** cemi generation examples

  auto my = new LData_cEMI();
  my.message_code = MC.LDATA_REQ;
  my.standard = true;
  my.donorepeat = true;
  my.sys_broadcast = true;
  my.priority = 3;
  my.address_type_group = true;
  my.source = 4355;
  my.dest = 2305;
  my.tpci = TService.TDataGroup;
  my.apci_data_len = 3;
  my.apci = APCI.AGroupValueWrite;
  my.data = [7, 178];
  writefln("my to ubytes: %(%x %)", my.toUbytes());

  my = new LData_cEMI();
  my.message_code = MC.LDATA_REQ;
  my.source = 0x0000;
  my.dest = 0x1103;
  my.tservice = TService.TConnect;
  writefln("my tconnect to ubytes: %(%x %)", my.toUbytes());

  my = new LData_cEMI();
  my.message_code = MC.LDATA_REQ;
  my.source = 0x0000;
  my.dest = 0x1103;
  my.tservice = TService.TDataConnected;
  my.apci = APCI.ADeviceDescriptorRead;
  my.apci_data_len = 1;
  my.tiny_data = 0x00;
  writefln("my tdataconnectd descrread to ubytes: %(%x %)", my.toUbytes());

  my = new LData_cEMI();
  my.message_code = MC.LDATA_REQ;
  my.source = 0x0000;
  my.dest = 0x1103;
  my.tservice = TService.TDataConnected;
  my.apci = APCI.ARestart;
  my.apci_data_len = 1;
  my.tiny_data = 0x00;
  writefln("my tdataconnected restart to ubytes: %(%x %)", my.toUbytes());
  **/

  while(true) {
    dsm.processMessages();
    baos.processIncomingData();
    // check connections for timeout
    Thread.sleep(1.msecs);
  }
}
