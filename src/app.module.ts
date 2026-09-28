import { Module } from '@nestjs/common';
import { AppController } from './app.controller.js';
import { ScheduleModule } from '@nestjs/schedule';
import { AppService } from './app.service.js';
import { PrismaModule } from './prisma/prisma.module.js';
import { UsersModule } from './users/users.module.js';
import { BooksModule } from './books/books.module.js';
import { BorrowingsModule } from './borrowings/borrowings.module.js';
import { QueueModule } from './queue/queue.module.js';
import { SchedulerModule } from './scheduler/scheduler.module.js';



@Module({
  imports: [ScheduleModule.forRoot(), PrismaModule, UsersModule ,BooksModule, BorrowingsModule, QueueModule ,SchedulerModule],
  controllers: [AppController],
  providers: [AppService],
})
export class AppModule {}