import 'package:flutter/material.dart';

class DriverNGoApp extends StatelessWidget {
  const DriverNGoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(body: Center(child: Text('Meet \'N Go Driver'))),
    );
  }
}

void main() => runApp(const DriverNGoApp());
