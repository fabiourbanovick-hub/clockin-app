import 'package:flutter/material.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'ClockIn App',
      home: Scaffold(
        appBar: AppBar(title: const Text('ClockIn App')),
        body: const Center(
          child: Text('App criado com sucesso'),
        ),
      ),
    );
  }
}
