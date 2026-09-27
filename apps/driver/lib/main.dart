import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:mng_core/mng_core.dart';

class DriverNGoApp extends StatelessWidget {
  const DriverNGoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ScreenUtilInit(
      designSize: const Size(390, 844),
      minTextAdapt: true,
      splitScreenMode: true,
      builder: (_, _) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: MngTheme.light,
        home: const Scaffold(body: Center(child: Text('Meet \'N Go Driver'))),
      ),
    );
  }
}

void main() => runApp(const DriverNGoApp());
