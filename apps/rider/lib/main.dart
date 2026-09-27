import 'package:flutter/material.dart';

class RideNGoApp extends StatelessWidget {
  const RideNGoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(body: Center(child: Text('Meet \'N Go'))),
    );
  }
}

void main() => runApp(const RideNGoApp());
