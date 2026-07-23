// ignore_for_file: avoid_print
import 'dart:io'; void main() async { var f = File('test.bin'); await f.writeAsBytes([1, 2, 3, 4, 5]); var raf = await f.open(mode: FileMode.append); await raf.setPosition(0); await raf.writeFrom([9]); await raf.close(); print(await f.readAsBytes()); }

