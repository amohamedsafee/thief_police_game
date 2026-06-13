import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'firebase_options.dart';
import 'core/app_theme.dart';
import 'screens/splash_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  String? firebaseError;
  try {
    await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  } catch (e) {
    firebaseError = e.toString();
  }

  runApp(_App(firebaseError: firebaseError));
}

class _App extends StatelessWidget {
  const _App({this.firebaseError});
  final String? firebaseError;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Thief & Police',
      theme: ThemeData(
        scaffoldBackgroundColor: AppTheme.primary,
        primaryColor: AppTheme.primary,
        splashFactory: InkRipple.splashFactory,  // smoother ink ripples
        pageTransitionsTheme: const PageTransitionsTheme(
          builders: {
            TargetPlatform.android: FadeUpwardsPageTransitionsBuilder(),
            TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
          },
        ),
      ),
      home: SplashScreen(initError: firebaseError),
      debugShowCheckedModeBanner: false,
    );
  }
}